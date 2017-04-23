{CompositeDisposable, Disposable, Emitter, Range} = require 'atom'
settings = require './settings'

defaultIgnoreCommands = [
  'cursor-history:next',
  'cursor-history:prev',
  'cursor-history:next-within-editor',
  'cursor-history:prev-within-editor',
  'cursor-history:clear',
]

findEditorForPaneByURI = (pane, URI) ->
  for item in pane.getItems() when atom.workspace.isTextEditor(item)
    return item if item.getURI() is URI

closestTextEditor = (target) ->
  target?.closest?('atom-text-editor')?.getModel()

createLocation = (type, editor) ->
  return {
    type: type
    editor: editor
    point: editor.getCursorBufferPosition()
    URI: editor.getURI()
  }

module.exports =
  config: settings.config
  history: null
  subscriptions: null
  ignoreCommands: null

  onDidChangeLocation: (fn) -> @emitter.on('did-change-location', fn)
  onDidUnfocus: (fn) -> @emitter.on('did-unfocus', fn)

  activate: ->
    @subscriptions = new CompositeDisposable
    @emitter = new Emitter

    jump = @jump.bind(this)
    @subscriptions.add atom.commands.add 'atom-text-editor',
      'cursor-history:next': -> jump(@getModel(), 'next')
      'cursor-history:prev': -> jump(@getModel(), 'prev')
      'cursor-history:next-within-editor': -> jump(@getModel(), 'next', withinEditor: true)
      'cursor-history:prev-within-editor': -> jump(@getModel(), 'prev', withinEditor: true)
      'cursor-history:clear': => @history?.clear()
      'cursor-history:toggle-debug': -> settings.toggle 'debug', log: true

    @observeMouse()
    @observeCommands()
    @observeSettings()

    @onDidChangeLocation ({oldLocation, newLocation}) =>
      oldPoint = oldLocation.point
      newPoint = newLocation.point

      if oldPoint.isGreaterThan(newPoint)
        {row, column} = oldPoint.traversalFrom(newPoint)
      else
        {row, column} = newPoint.traversalFrom(oldPoint)

      if (row > settings.get('rowDeltaToRemember')) or
          (row is 0 and column > settings.get('columnDeltaToRemember'))
        @saveHistory(oldLocation, subject: "Cursor moved")

    @onDidUnfocus ({oldLocation}) =>
      @saveHistory(oldLocation, subject: "Save on focus lost")

  deactivate: ->
    @subscriptions.dispose()
    @history?.destroy()
    [@subscriptions, @history] = []

  observeSettings: ->
    @subscriptions.add settings.observe 'keepSingleEntryPerBuffer', (newValue) =>
      if newValue
        @history?.uniqueByBuffer()

    @subscriptions.add settings.observe 'ignoreCommands', (newValue) =>
      @ignoreCommands = defaultIgnoreCommands.concat(newValue)

  saveHistory: (location, {subject, setIndexToHead}={}) ->
    @history ?= new (require './history')
    @history.add(location, {setIndexToHead})
    @logHistory("#{subject} [#{location.type}]") if settings.get('debug')

  # Mouse handling is not primal purpose of this package
  # I dont' use mouse basically while coding.
  # So to keep codebase minimal and simple,
  #  I don't use editor::onDidChangeCursorPosition() to track cursor position change
  #  caused by mouse click.
  #
  # When mouse clicked, cursor position is updated by atom core using setCursorScreenPosition()
  # To track cursor position change caused by mouse click, I use mousedown event.
  #  - Event capture phase: Cursor position is not yet changed.
  #  - Event bubbling phase: Cursor position updated to clicked position.
  observeMouse: ->
    locationStack = []
    handleCapture = (event) ->
      editor = closestTextEditor(event.target)
      if editor?.getURI()
        locationStack.push(createLocation('mousedown', editor))

    handleBubble = (event) =>
      if closestTextEditor(event.target)?.getURI()
        setTimeout =>
          @checkLocationChange(location) if location = locationStack.pop()
        , 100

    workspaceElement = atom.views.getView(atom.workspace)
    workspaceElement.addEventListener('mousedown', handleCapture, true)
    workspaceElement.addEventListener('mousedown', handleBubble, false)

    @subscriptions.add new Disposable ->
      workspaceElement.removeEventListener('mousedown', handleCapture, true)
      workspaceElement.removeEventListener('mousedown', handleBubble, false)

  observeCommands: ->
    isInterestingCommand = (type) =>
      (':' in type) and (type not in @ignoreCommands)

    @locationStackForTestSpec = locationStack = []
    trackLocationTimeout = null
    trackLocationChangeEdgeDebounced = (type, editor) ->
      if trackLocationTimeout?
        clearTimeout(trackLocationTimeout)
      else
        locationStack.push(createLocation(type, editor))
      trackLocationTimeout = setTimeout ->
        trackLocationTimeout = null
      , 100

    @subscriptions.add atom.commands.onWillDispatch ({type, target}) ->
      editor = closestTextEditor(target)
      if editor?.getURI() and isInterestingCommand(type)
        trackLocationChangeEdgeDebounced(type, editor)

    @subscriptions.add atom.commands.onDidDispatch ({type, target}) =>
      return if locationStack.length is 0
      editor = closestTextEditor(target)
      if editor?.getURI() and isInterestingCommand(type)
        setTimeout =>
          # To wait cursor position is set on final destination in most case.
          @checkLocationChange(location) if location = locationStack.pop()
        , 100

  checkLocationChange: (oldLocation) ->
    editor = atom.workspace.getActiveTextEditor()
    return unless editor

    if editor.element.hasFocus() and (editor.getURI() is oldLocation.URI)
      # Move within same buffer.
      newLocation = createLocation(oldLocation.type, editor)
      @emitter.emit('did-change-location', {oldLocation, newLocation})
    else
      @emitter.emit('did-unfocus', {oldLocation})

  jump: (editor, direction, {withinEditor}={}) ->
    return unless @history?
    wasAtHead = @history.isIndexAtHead()
    if withinEditor
      entry = @history.get(direction, URI: editor.getURI())
    else
      entry = @history.get(direction)

    return unless entry?
    # FIXME, Explicitly preserve point, URI by setting independent value,
    # since its might be set null if entry.isAtSameRow()
    {point, URI} = entry

    needToLog = true
    if (direction is 'prev') and wasAtHead
      location = createLocation('prev', editor)
      @saveHistory(location, setIndexToHead: false, subject: "Save head position")
      needToLog = false

    activePane = atom.workspace.getActivePane()
    if editor.getURI() is URI
      @land(editor, point, direction, log: needToLog)
    else if item = findEditorForPaneByURI(activePane, URI)
      activePane.activateItem(item)
      @land(item, point, direction, forceFlash: true, log: needToLog)
    else
      atom.workspace.open(URI, searchAllPanes: settings.get('searchAllPanes')).then (editor) =>
        @land(editor, point, direction, forceFlash: true, log: needToLog)

  land: (editor, point, direction, options={}) ->
    originalRow = editor.getCursorBufferPosition().row
    editor.setCursorBufferPosition(point, autoscroll: false)
    editor.scrollToCursorPosition(center: true)

    if settings.get('flashOnLand')
      if options.forceFlash or (originalRow isnt point.row)
        @flash(editor)

    if settings.get('debug') and options.log
      @logHistory(direction)


  flashMarker: null
  flash: (editor) ->
    @flashMarker?.destroy()
    cursorPosition = editor.getCursorBufferPosition()
    @flashMarker = editor.markBufferPosition(cursorPosition)
    decorationOptions = {type: 'line', class: 'cursor-history-flash-line'}
    editor.decorateMarker(@flashMarker, decorationOptions)

    destroyMarker = =>
      disposable?.destroy()
      disposable = null
      @flashMarker?.destroy()

    disposable = editor.onDidChangeCursorPosition(destroyMarker)
    # [NOTE] animation-duration has to be shorter than this value(1sec)
    setTimeout(destroyMarker, 1000)

  logHistory: (msg) ->
    s = """
    # cursor-history: #{msg}
    #{@history.inspect()}
    """
    console.log s, "\n\n"
