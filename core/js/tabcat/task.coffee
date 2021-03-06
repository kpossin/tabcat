###
Copyright (c) 2013, Regents of the University of California
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  1. Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
###
# Methods for use by tasks, especially to record task data.
#
# Most of this code assumes that it will only be used by one task ever,
# since each new task is a separate HTML document with a separate page load.

@tabcat ?= {}
tabcat.task = {}


# by default, we attempt to upload a chunk of events every 5 seconds
DEFAULT_EVENT_LOG_SYNC_INTERVAL = 5000

# default timeout for tabcat.task.start() and tabcat.task.finish()
DEFAULT_TIMEOUT = 3000

# default time to wait after finishing task
DEFAULT_MIN_WAIT = 1000

# default duration of fade at end of task
DEFAULT_FADE_DURATION = 200

# DB where design docs and task content is stored
TABCAT_DB = 'tabcat'

# DB where we store patient and encounter docs
DATA_DB = 'tabcat-data'

# so we don't have to type window.localStorage in functions
localStorage = @localStorage


# The CouchDB document for this task. This stores information about the task as
# a whole. We can store this in memory because each task is a single page.
taskDoc = null

# An array of events recorded during the task (e.g. user clicked). These are
# are stored to CouchDB in chunks periodically. This is independent from
# tabcat.task.start()
eventLog = []

# This tracks where we are in the event log in terms of items that we've
# successfully stored in the DB
eventSyncStartIndex = 0

# This tracks where we are in the event log in terms of items that we've
# attempted to upload and MAY be stored on the server. Sections of eventLog
# log before this index should be considered read-only.
eventSyncEndIndex = 0

# The current xhr for an AJAX request to upload events (only one is allowed at
# a time).
eventSyncXHR = null

# ID of the timer for event uploads
eventSyncIntervalId = null



# Does the patient have the device? Call with an argument (true or false) to
# set whether the patient has device.
#
# tabcat.task.start() sets this to true unless you call it with the
# examinerAdministered option.
#
# The return-to-examiner.html page sets this back to false
tabcat.task.patientHasDevice = (value) ->
  if value?
    if value
      localStorage.patientHasDevice = 'true'
    else
      localStorage.removeItem('patientHasDevice')

  return (localStorage.patientHasDevice is 'true')


# Promise: Initialize the task. This does lots of things:
# - start automatically logging when the browser resizes
# - check if it's okay to continue (correct PHI, browser capabilities, etc)
# - create an initial task doc with start time, browser info, viewport,
#   patient code, etc.
#
# options:
# - eventLogSyncInterval: how often to upload chunks of the event log, in
#   milliseconds (default is 5 seconds). Set this to 0 to disable periodic
#   uploads.
# - examinerAdministered: should the examiner have the device before the task
#   starts?
# - timeout: network timeout, in milliseconds (default 3000)
# - trackViewport: should we log changes to the viewport in the event log?
#   (see tabcat.task.trackViewportInEventLog())
tabcat.task.start = _.once((options) ->
  now = $.now()
  timeout = options?.timeout ? DEFAULT_TIMEOUT

  # TODO: redirect to the return-to-examiner page if the patient has the device
  # and this is examiner-administered
  if not options?.examinerAdministered
    tabcat.task.patientHasDevice(true)

  # important to do this AFTER patientHasDevice(true), to keep from prompting
  # the patient for the password
  #
  # timeout won't actually come into play here unless the examiner has
  # the device
  tabcat.ui.requireUserAndEncounter(timeout: options?.timeout)

  taskDoc =
      _id: tabcat.couch.randomUUID()
      type: 'task'
      browser: tabcat.task.getBrowserInfo()
      clockLastStarted: tabcat.clock.lastStarted()
      encounterId: tabcat.encounter.getId()
      patientCode: tabcat.encounter.getPatientCode()
      startedAt: tabcat.clock.now()
      startViewport: tabcat.task.getViewportInfo()
      name: tabcat.task.getTaskName()
      user: tabcat.user.get()

  if options?.trackViewport
    tabcat.task.trackViewportInEventLog()

  # periodically upload chunks of the event log
  eventLogSyncInterval = (
    options?.eventLogSyncInterval ? DEFAULT_EVENT_LOG_SYNC_INTERVAL)

  if eventLogSyncInterval > 0
    eventSyncIntervalId = window.setInterval(
      tabcat.task.syncEventLog, eventLogSyncInterval)

  # create the task document on the server; we'll update it when
  # tabcat.task.finish() is called. This allows us to fail fast if there's
  # a problem with the server, and also to detect tasks that were started
  # but not finished.
  createTaskDoc = (additionalFields) ->
    $.extend(taskDoc, additionalFields)
    tabcat.db.putDoc(DATA_DB, taskDoc)

  # fetch login information and the task's design doc (.), and create
  # the task document, with some additional fields filled in
  $.when(tabcat.couch.getDoc(null, '.', timeout: timeout),
         tabcat.config.get(timeout: timeout)).then(
    ([designDoc], config) ->
      taskDoc.version = designDoc?.kanso?.config?.version

      if config.limitedPHI
        taskDoc.limitedPHI =
          clockOffset: tabcat.clock.offset()

      tabcat.db.putDoc(DATA_DB, taskDoc, now: now, timeout: timeout)
  )
)


# Promise (can't fail): upload the portion of the event log that has not
# already been stored in the DB. You usually don't need to call this directly;
# by default, tabcat.task.start() will cause it to be called periodically.
#
# If options.force is true, this will abort pending syncs unless
# they were already uploading all the event log items we wanted to.
#
# You can set a timeout in milliseconds with options.timeout.
# You can make this relative to a time in the past with options.now
#
# You must call tabcat.task.start() before calling this (you don't have to
# wait for the promise it returns to resolve).
tabcat.task.syncEventLog = (options) ->
  # require taskDoc
  if not taskDoc?
    throw new Error('no taskDoc; call tabcat.task.start() first')

  # don't upload events if there's already one pending
  if eventSyncXHR?
    # if there's more to upload, abort the current upload and restart
    if options?.force and eventLog.length > eventSyncEndIndex
      # if we're spilling to localStorage, this won't be a real xhr
      if eventSyncXHR.abort?
        eventSyncXHR.abort()
      eventSyncXHR = null
    else
      return eventSyncXHR

  # if no new events to upload, do nothing
  if eventLog.length <= eventSyncStartIndex
    return $.Deferred().resolve()

  # upload everything we haven't so far
  #
  # Store value of eventSyncEndIndex in local scope just in case something
  # weird happens with multiple overlapping callbacks
  endIndex = eventSyncEndIndex = eventLog.length

  # This is only called by tabcat.task.start(), so we can safely assume
  # taskDoc exists and has the fields we want.
  eventLogDoc = {
    _id: tabcat.couch.randomUUID()
    type: 'eventLog'
    taskId: taskDoc._id
    encounterId: taskDoc.encounterId
    patientCode: taskDoc.patientCode
    user: tabcat.user.get()
    startIndex: eventSyncStartIndex
    items: eventLog.slice(eventSyncStartIndex, endIndex)
  }

  eventSyncXHR = tabcat.db.putDoc(
    DATA_DB, eventLogDoc, _.pick(options ? {}, 'now', 'timeout'))

  # track that events were successfully uploaded
  eventSyncXHR.then(-> eventSyncStartIndex = endIndex)

  # track that we're ready for a new XHR
  # (this also implicitly returns eventSyncXHR)
  eventSyncXHR.always(-> eventSyncXHR = null)


# Log an event whenever the viewport changes (scroll/resize). You can also
# access this with the trackViewport option to tabcat.task.start()
#
# If there is a series of viewport changes without other events logged between
# them, we try to only keep the most recent one.
#
# TODO: give a way to turn this on/off in the middle of a task
tabcat.task.trackViewportInEventLog = _.once(->
  isViewportLogItem = (item) ->
    item? and not item.interpretation? and _.isEqual(
      _.keys(item.state), ['viewport'])

  handler = (event) ->
    # if the last event log item is also a viewport event, delete it, assuming
    # we haven't already tried to upload it to the DB
    if (eventLog.length > eventSyncEndIndex and
        isViewportLogItem(_.last(eventLog)))
      eventLog.pop()

    tabcat.task.logEvent(viewport: tabcat.task.getViewportInfo(), event)

  $(window).resize(handler)
  $(window).scroll(handler)
)


# splash a "Task complete!" page for the user, upload task info to the DB, and
#  return to the task selector page.
#
# Note that this will blow away everything in the <body> tag, so grab anything
# you need before calling this method.
#
# options:
# - fadeDuration: fade duration in milliseconds (default 200)
# - minWait: minimum number of milliseconds to wait before redirecting to
#   another page (default 1000)
# - timeout: maximum amount of time for db operations to take (default 3000)
tabcat.task.finish = (options) ->
  now = $.now()
  timeout = options?.timeout ? DEFAULT_TIMEOUT

  clockNow = tabcat.clock.now()

  minWait = options?.minWait ? DEFAULT_MIN_WAIT
  fadeDuration = options?.fadeDuration ? DEFAULT_FADE_DURATION

  # start the timer
  waitedForMinWait = tabcat.ui.wait(minWait)

  # splash up Task complete! screen
  $body = $('body')
  $body.empty()
  $body.hide()
  tabcat.ui.linkEmToPercentOfHeight($body)
  $body.attr('class', 'fullscreen unselectable blueBackground taskComplete')
  $messageP = $('<p class="message">Task complete!</p>')
  $body.append($messageP)
  $body.fadeIn(duration: fadeDuration)

  tabcat.encounter.markTaskFinished(tabcat.task.getTaskName())

  # make sure start() has completed!
  tabcat.task.start().then(->
    taskDoc.finishedAt = clockNow
    if options?.interpretation?
      taskDoc.interpretation = options?.interpretation

    $.when(
      tabcat.db.putDoc(DATA_DB, taskDoc, now: now, timeout: timeout),
      tabcat.task.syncEventLog(force: true, now: now, timeout: timeout),
      waitedForMinWait).then(
      ->
        if tabcat.task.patientHasDevice()
          window.location = '../core/return-to-examiner.html'
        else
          window.location = '../core/tasks.html'
      )
  )


# get basic information about the browser. This should not change
# over the course of the task
# TODO: add screen DPI/physical size, if available
tabcat.task.getBrowserInfo = ->
  screenHeight: screen.height
  screenWidth: screen.width
  userAgent: navigator.userAgent


# Get information about the viewport. If you want to track changes to the
# viewport (scroll/resize) in eventLog, it's recommended you
# use tabcat.task.trackViewportInEventLog() rather than including viewport
# info in other events you log.
tabcat.task.getViewportInfo = ->
  $window = $(window)
  return {
    left: $window.scrollLeft()
    top: $window.scrollTop()
    width: $window.width()
    height: $window.height()
  }


# get the bounding box for the given DOM element (not jQuery selector),
# with fields "top", "bottom", "left", and "right".
#
# we use getBoundingClientRect() rather than the jQuery alternative to get
# floating-point values
tabcat.task.getElementBounds = (element) ->
  # unwrap jQuery elements
  if not element.getBoundingClientRect?
    element = element[0]

  # some browsers include height and width, but it's redundant
  _.pick(element.getBoundingClientRect(), 'top', 'bottom', 'left', 'right')


# Appends an event to the event log, with these fields:
# - state: object representing the state of the world at the time the event
#   happened. Common fields are:
#   - intensity: intensity
#   - practiceMode: are we in practice mode? (don't set at all if false)
#   - stimuli: task-specific info about what's actually shown on the screen.
#     Some stimuli fields so far: "lines", "practiceCaption"
#   - trialNum: which trial we're on (0-indexed, includes practice trials)
# - event: a summary of the event (currently we keep type, pageX, and pageY).
#   You can pass in a jQuery event, or just a string for event type.
# - interpretation: the meaning of the event (i.e. was it the right answer?)
#   Common fields are:
#   - correct (boolean): did the patient select the correct answer
#   - intensityChange: change in intensity (easiness) due to patient's choice
#   - reversal (boolean): was this a reversal?
# - now: if not set, the time of the event relative to start of encounter, or
#   tabcat.clock.now() if "event" is undefined
#
# state, event, and interpretation are not included if null/undefined.
#
# You should aim for readable, compact formats for state and interpretation.
# For most true/false values, only include the field if it's true.
tabcat.task.logEvent = (state, event, interpretation, now) ->
  if not now?  # ...when?
    if event?.timeStamp?
      now = event.timeStamp - tabcat.clock.offset()
    else
      now = tabcat.clock.now()

  eventLogItem = now: now

  if typeof event is 'string'
    eventLogItem.event = {type: event}
  else if event?
    eventLogItem.event = _.pick(event, 'pageX', 'pageY', 'type')

    # include touch events too
    originalEvent = event.originalEvent ? event
    for key in ['changedTouches', 'targetTouches', 'touches']
      touches = originalEvent[key]
      if touches?
        eventLogItem.event[key] = (
          _.pick(touch, 'identifier', 'pageX', 'pageY') for touch in touches)

  if interpretation?
    eventLogItem.interpretation = interpretation

  if state?
    eventLogItem.state = state

  eventLog.push(eventLogItem)

  return


# Get a (shallow) copy of the event log
tabcat.task.getEventLog = ->
  eventLog.slice(0)


# Get the ID of the current task, or null if start() hasn't been called
tabcat.task.getTaskId = ->
  taskDoc?._id


# Get the task name from the URL
tabcat.task.getTaskName = ->
  _.last(window.location.pathname.split('/'), 2)[0]


NON_TASK_DESIGN_DOCS = ['core']

# Get the name of all tabcat tasks. This assumes our current URL points
# to a doc in the tabcat DB
tabcat.task.getAllTaskNames = ->
  tabcat.couch.getDoc(TABCAT_DB, '_all_docs').then(
    (response) ->
      (row.key[8..] for row in response.rows \
        when row.key[0..7] is '_design/' and \
          row.key[8..] not in NON_TASK_DESIGN_DOCS)
  )


# implements adaptive difficulty. Keeps track of an "intensity"
# (higher intensity means easier) and raises or lowers intensity
# depending on how the patient does.
#
# Sample usage:
#
# s = tabcat.task.Staircase(stepsUp: 2, maxIntensity: 50)
# s.addResult(true)   # got it correct
# s.addResult(false)  # got it wrong
#
# You can set the following instance variables from the constructor:
#
# intensity: how easy is the task? (default 0)
# lastIntensityChange: previous intensity change (default 0, also
#   clamped between min/max intensity)
# maxIntensity: upper limit for intensity (default is no limit)
# minIntensity: lower limit for intensity (default is no limit)
# numReversals: how many reversals so far? (default 0)
# stepsDown: how much to lower intensity on correct response? (default 1)
# stepsUp: how much to raise intensity on incorrect response? (default 1)
# trialNum: which trial number are we on?
#
# If multiple objects are provided, we'll combine them together with
# _.extend(). Note that other Staircase objects can be used as options;
# to continue where another staircase left off, with some changes, do
# something like:
#
# s = tabcat.task.Staircase(oldStaircase, intensity: 15, stepsUp: 3)
#
# We recommend using negative intensity values for tasks that get harder
# as a number of things increases (e.g. more stars to remember)
tabcat.task.Staircase = class
  constructor: (options...) ->
    options = _.extend({}, options...)

    @intensity = options.intensity ? 0
    @lastIntensityChange = options.lastIntensityChange ? 0
    @maxIntensity = options.maxIntensity ? null
    @minIntensity = options.minIntensity ? null
    @numReversals = options.numReversals ? 0
    @stepsDown = options.stepsDown ? 1
    @stepsUp = options.stepsUp ? 1
    @trialNum = options.trialNum ? 0

    @intensity = tabcat.math.clamp(@minIntensity, @intensity, @maxIntensity)

  # add a result (true for correct, false for incorrect) and return an
  # interpretation of the result, with these fields:
  #
  # correct: true, false or null
  # intensityChange: change in intensity as a result (omitted if 0)
  # reversal: did this change cause a reversal? (only included if true)
  #
  # If we are prevented by min/max intensity from changing intensity
  # as much as we would like, we count that as a reversal. However, we
  # if the next change is intensity is in the opposite direction, we
  # don't count that as another reversal (essentially, we treat it as
  # if the intensity value hit the wall and bounced back).
  #
  # if correct is null, @trialNum will be incremented, but nothing else
  # will change.
  addResult: (correct) ->
    @trialNum += 1

    # normalize to true, false, or null
    correct = if correct? then !!correct else null

    interpretation =
      correct: correct

    # bail out if result is not scored
    if not correct?
      return interpretation

    change = if correct then -@stepsDown else @stepsUp
    lastIntensity = @intensity

    rawIntensity = lastIntensity + change
    @intensity = tabcat.math.clamp(@minIntensity, rawIntensity, @maxIntensity)

    intensityChange = @intensity - lastIntensity
    if intensityChange
      interpretation.intensityChange = intensityChange

    reversal = (
      intensityChange * @lastIntensityChange < 0 or
      @intensity != rawIntensity)  # i.e. we hit the floor/ceiling

    @lastIntensityChange = intensityChange

    if reversal
      @numReversals += 1
      interpretation.reversal = true

    return interpretation
