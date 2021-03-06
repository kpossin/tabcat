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

# LOOK AND FEEL

# fit in a square, so all orientations work the same
ASPECT_RATIO = 1/1

# range of line length, as a % of container width/height
SHORT_LINE_MIN_LENGTH = 40
SHORT_LINE_MAX_LENGTH = 50
# width of lines, as a % of container width/height. Also used for spacing.
LINE_WIDTH = 7
# how much bigger to make invisible target around lines, as a % of width/height
TARGET_BORDER_WIDTH = 3
# height of practice caption, as a % of container height
CAPTION_HEIGHT = 30
# offest between line centers, as a % of the shorter line's length
LINE_OFFSET_AT_CENTER = 50
# number of positions for lines (currently, top and bottom of screen).
# these work with the layout-0 and layout-1 CSS classes
NUM_LAYOUTS = 2
# how long a fade should take, in msec
FADE_DURATION = 400


# STAIRCASING PARAMETERS

# intensity is the % the longer line is longer than the shorter one
MIN_INTENSITY = 1
MAX_INTENSITY = 50
# decrease intensity by this much after each correct response
STEPS_DOWN = 1
# increase increase by this much after each incorrect response
STEPS_UP = 3
# start practice mode here
PRACTICE_START_INTENSITY = 40
# jump to this intensity after exiting practice mode
START_INTENSITY = 15
# get this many correct in a row to leave practice mode
PRACTICE_MAX_STREAK = 4
# get this many correct in a row to turn off the practice mode instructions
PRACTICE_CAPTION_MAX_STREAK = 2
# task is done after this many reversals (change in direction of
# intensity change). Bumping against the floor/ceiling also counts
# as a reversal
MAX_REVERSALS = 14


# VARIABLES

intensity = PRACTICE_START_INTENSITY
# number of practice trials correct in a row
practiceStreakLength = 0
# used to track reversals. not maintained in practice mode
lastIntensityChange = 0

# number of reversals so far
numReversals = 0
# which trial we're on (0-indexed)
trialNum = 0


# FUNCTIONS

inPracticeMode = -> practiceStreakLength < PRACTICE_MAX_STREAK

shouldShowPracticeCaption = ->
  practiceStreakLength < PRACTICE_CAPTION_MAX_STREAK


# call this when the user taps on a line. correct is a boolean
# this will update practiceStreakLength, intensity, lastIntensityChange,
# and intensitiesAtReversal
registerResult = (event) ->
  state = getTaskState()

  correct = event.data.isLonger

  change = if correct then -STEPS_DOWN else STEPS_UP

  lastIntensity = intensity
  intensity = tabcat.math.clamp(
    MIN_INTENSITY, lastIntensity + change, MAX_INTENSITY)
  intensityChange = intensity - lastIntensity

  interpretation =
    correct: correct
    intensityChange: change

  if inPracticeMode()
    if correct
      practiceStreakLength += 1
      if not inPracticeMode()  # i.e. we just left practice mode
        intensity = START_INTENSITY
        lastIntensityChange = 0
    else
      practiceStreakLength = 0
  else
    wasReversal = (
      intensityChange * lastIntensityChange < 0 or
      intensityChange is 0)  # i.e. we hit the floor/ceiling

    if wasReversal
      numReversals += 1
      interpretation.reversal = true

    lastIntensityChange = intensityChange

  tabcat.task.logEvent(state, event, interpretation)

  trialNum += 1


# generate data, including CSS, for the next trial
getNextTrial = ->
  shortLineLength = tabcat.math.randomUniform(SHORT_LINE_MIN_LENGTH,
                                              SHORT_LINE_MAX_LENGTH)

  longLineLength = shortLineLength * (1 + intensity / 100)

  # Going to make a sort of T-shaped layout, and rotate it later.
  # The top of the T is the "arm" and the vertical part is the "stem"

  # Alternate between sideways and upright, but pick orientation
  # randomly within that.
  angle = 90 * (trialNum % 2)
  if tabcat.math.coinFlip()
    angle += 180

  if shouldShowPracticeCaption()
    # when showing the practice caption, always make the vertical
    # line short
    armIsShort = (tabcat.math.mod(angle, 180) == 90)
  else
    armIsShort = tabcat.math.coinFlip()

  if armIsShort
    [armLength, stemLength] = [shortLineLength, longLineLength]
  else
    [armLength, stemLength] = [longLineLength, shortLineLength]

  totalHeight = stemLength + LINE_WIDTH * 2
  verticalMargin = (100 - totalHeight) / 2

  arm =
    top: verticalMargin
    bottom: verticalMargin + LINE_WIDTH
    height: LINE_WIDTH
    left: (100 - armLength) / 2
    right: (100 + armLength) / 2
    width: armLength

  stem =
    top: verticalMargin + 2 * LINE_WIDTH
    bottom: 100 - verticalMargin
    height: stemLength
    width: LINE_WIDTH

  # offset stem to the left or right to avoid perseverative tapping
  # in the center of the screen
  if tabcat.math.coinFlip()
    stem.left = arm.left + LINE_WIDTH
  else
    stem.left = arm.right - LINE_WIDTH * 2
  stem.right = stem.left + LINE_WIDTH

  # rotate the "T" shape
  line1Box = rotatePercentBox(arm, angle)
  line2Box = rotatePercentBox(stem, angle)

  # if we want to show a practice caption, shift the whole thing down
  if shouldShowPracticeCaption()
    offset = CAPTION_HEIGHT - Math.min(line1Box.top, line2Box.top)
    line1Box.top += offset
    line1Box.bottom += offset
    line2Box.top += offset
    line2Box.bottom += offset

  line1TargetBox = makeTargetBox(line1Box)
  line2TargetBox = makeTargetBox(line2Box)

  line1Css = percentBoxToCss(line1Box)
  line1TargetCss = percentBoxToCss(line1TargetBox)
  line2Css = percentBoxToCss(line2Box)
  line2TargetCss = percentBoxToCss(line2TargetBox)

  return {
    line1:
      css: line1Css
      isLonger: (armLength >= stemLength)
      targetCss: line1TargetCss
    line2:
      css: line2Css
      isLonger: (stemLength >= armLength)
      targetCss: line2TargetCss
    angle: angle
  }


# event handler for taps on lines. either fade in the next trial,
# or call finishTask()
showNextTrial = (event) ->
  # don't emulate mousedown event if we get a touch event
  if event?.preventDefault?
    event.preventDefault()

  if event?.data?
    registerResult(event)

  if numReversals >= MAX_REVERSALS
    interpretation =
      intensitiesAtReversal: e.state.intensity \
        for e in tabcat.task.getEventLog() \
        when e.interpretation?.reversal
    tabcat.task.finish(interpretation: interpretation)
  else
    $nextTrialDiv = getNextTrialDiv()
    $('#task').empty()
    $('#task').append($nextTrialDiv)
    tabcat.ui.fixAspectRatio($nextTrialDiv, ASPECT_RATIO)
    tabcat.ui.linkEmToPercentOfHeight($nextTrialDiv)
    $nextTrialDiv.fadeIn(duration: FADE_DURATION)


# create the next trial, and return the div containing it, but don't
# show it or add it to the page (showNextTrial() does this)
getNextTrialDiv = ->
  # get line offsets and widths for next trial
  trial = getNextTrial()

  # construct divs for these lines
  $line1Div = $('<div></div>', class: 'line')
  $line1Div.css(trial.line1.css)
  $line1TargetDiv = $('<div></div>', class: 'line-target')
  $line1TargetDiv.css(trial.line1.targetCss)
  $line1TargetDiv.on('mousedown touchstart', trial.line1, showNextTrial)

  $line2Div = $('<div></div>', class: 'line')
  $line2Div.css(trial.line2.css)
  $line2TargetDiv = $('<div></div>', class: 'line-target')
  $line2TargetDiv.css(trial.line2.targetCss)
  $line2TargetDiv.on('mousedown touchstart', trial.line2, showNextTrial)

  # put them in an offscreen div
  $containerDiv = $('<div></div>')
  $containerDiv.hide()
  $containerDiv.append($line1Div, $line1TargetDiv, $line2Div, $line2TargetDiv)
  $containerDiv.on('mousedown touchstart', catchStrayTouchStart)

  # show practice caption, if required
  if shouldShowPracticeCaption()
    $practiceCaptionDiv = $('<div></div>', class: 'practice-caption')
    $practiceCaptionDiv.html('Tap the longer line<br>' +
      ' quickly and accurately.')
    $containerDiv.append($practiceCaptionDiv)

  return $containerDiv


rotatePercentBox = (box, angle) ->
  if (angle % 90 != 0)
    throw Error("angle must be a multiple of 90")

  angle = tabcat.math.mod(angle, 360)
  if (angle == 0)
    return box

  return rotatePercentBox({
    top: 100 - box.right
    bottom: 100 - box.left
    height: box.width
    left: box.top
    right: box.bottom
    width: box.height
  }, angle - 90)


percentBoxToCss = (box) ->
  css = {}
  for own key, value of box
    css[key] = value + '%'

  return css


makeTargetBox = (box, borderWidth) ->
  borderWidth ?= TARGET_BORDER_WIDTH

  return {
    top: box.top - borderWidth
    bottom: box.top + borderWidth
    height: box.height + borderWidth * 2
    left: box.left - borderWidth
    right: box.right + borderWidth
    width: box.width + borderWidth * 2
  }


# summary of the current state of the task
getTaskState = ->
  state =
    intensity: intensity
    stimuli: getStimuli()
    trialNum: trialNum

  if inPracticeMode()
    state.practiceMode = true

  return state


# describe what's on the screen. helper for getTaskState()
getStimuli = ->
  stimuli =
    lines: (tabcat.task.getElementBounds(div) for div in $('div.line:visible'))

  $practiceCaption = $('div.practice-caption:visible')
  if $practiceCaption.length > 0
    stimuli.practiceCaption = tabcat.task.getElementBounds($practiceCaption[0])

  return stimuli


catchStrayTouchStart = (event) ->
  tabcat.task.logEvent(getTaskState(), event)


# INITIALIZATION
@initTask = ->
  tabcat.task.start(trackViewport: true)

  tabcat.ui.turnOffBounce()

  tabcat.ui.requireLandscapeMode($('#task'))

  $(showNextTrial)
