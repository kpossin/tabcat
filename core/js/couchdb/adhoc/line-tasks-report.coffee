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
_ = require('js/vendor/underscore')._
csv = require('js/vendor/ucsv')
patient = require('../patient')

MAX_REVERSALS = 20

LINE_TASKS = [
  'parallel-line-length',
  'perpendicular-line-length',
  'line-orientation'
]

COLUMNS_PER_TASK = MAX_REVERSALS + 3

patientHandler = (patientRecord) ->
  patientCode = patientRecord.patientCode

  taskToInfo = {}
  for encounter in patientRecord.encounters
    for task in encounter.tasks
      if task.finishedAt and task.eventLog? and task.name in LINE_TASKS
        # only keep the first task per patient
        if taskToInfo[task.name]
          continue

        # this isn't an off-by one; we discard the first trial because we
        # don't know when the patient first gets the task
        # using ? null because _.max() handles undefined differently
        numTrials = _.max(
          item?.state?.trialNum ? null for item in task.eventLog)

        firstAction = _.find(task.eventLog, (item) -> item?.interpretation?)
        totalTime = (task.finishedAt - firstAction.now) / 1000

        # use the "interpretation" field if we have it (phasing this out)
        intensitiesAtReversal = task?.interpretation?.intensitiesAtReversal

        if not intensitiesAtReversal?
          intensitiesAtReversal = (
            item.state.intensity for item in task.eventLog \
            when item?.interpretation?.reversal)

        taskToInfo[task.name] =
          totalTime: totalTime
          numTrials: numTrials
          timePerTrial: totalTime / numTrials
          intensitiesAtReversal: intensitiesAtReversal

  if _.isEmpty(taskToInfo)
    return

  data = []

  data[0] = patientCode
  for taskName, i in LINE_TASKS
    info = taskToInfo[taskName]
    if info?
      offset = i * COLUMNS_PER_TASK + 1
      data[offset] = info.totalTime
      data[offset + 1] = info.numTrials
      data[offset + 2] = info.timePerTrial
      for intensity, j in info.intensitiesAtReversal
        data[offset + 3 + j] = intensity

  # replace undefined with null, so arrayToCsv() works
  data = (x ? null for x in data)

  send(csv.arrayToCsv([data]))


taskHeader = (prefix) ->
  [prefix + 'Time', prefix + 'Trials', prefix + 'TimePerTrial'].concat(
    (prefix + i for i in [1..MAX_REVERSALS]))


exports.list = (head, req) ->
  keyType = req.path[req.path.length - 1]

  if not (req.path.length is 6 and keyType is 'patient')
    throw new Error('You may only dump the patient view')

  isoDate = (new Date()).toISOString().substring(0, 10)

  start(headers:
    'Content-Disposition': (
      "attachment; filename=\"line-tasks-report-#{isoDate}.csv"),
    'Content-Type': 'text/csv')

  csvHeader = ['patientCode'].concat(
    taskHeader('Par')).concat(
    taskHeader('Prp')).concat(
    taskHeader('LO'))

  send(csv.arrayToCsv([csvHeader]))

  patient.iterate(getRow, patientHandler)
