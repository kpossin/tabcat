# TASK INFO

# Promise: get a list of info about each task, with the keys index, icon,
# and description (index and icon are URLs), sorted by description.
getTaskInfo = ->
  tabcat.task.getAllTaskNames().then(
    (taskNames) ->
      taskDesignDocPromises = (
        tabcat.couch.getDoc(null, '../' + name) for name in taskNames)

      $.when(taskDesignDocPromises...).then(
        (taskDesignDocs...) ->
          taskInfo = _.sortBy(
            _.compact(designDocToTaskInfo(ddoc) for ddoc in taskDesignDocs),
              # temporary hack: put Line Orientation and DART task last
              #(item) -> item.description))
              (item) -> [item.description[0] is "D",
                         item.description[0] is "L",
                         item.description])

          # add info about which tasks were finished
          finished = tabcat.encounter.getTasksFinished()
          for task in taskInfo
            task.finished = !!finished[task.name]

          return taskInfo
      )
  )


# convert a design doc to task info, or return undefined if it's not a
# valid task
designDocToTaskInfo = (doc) ->
  urlRoot = '../../' + doc._id
  c = doc.kanso?.config

  if not (c? and c.index? and c.name? and c.description?)
    return

  if c.tabcat?.icon?
    icon = urlRoot + '/' + c.tabcat.icon
  else
    icon = 'img/icon.png'

  return {
    url: urlRoot + c.index
    icon: icon
    description: c.description
    name: c.name
  }


# get task info from the server, and then display an icon and a description
# for each task
showTasks = ->
  getTaskInfo().then((taskInfo) ->
    $('#taskList').empty()
    for task in taskInfo
      do (task) ->  # create a new scope to create separate bind() functions
        $div = $('<div></div>', class: 'task')

        if task.finished
          # make the icon the background, and the checkmark the foreground
          # TODO: use absolute positioning and z-indexes to do a real overlay
          $icon = $('<img>', class: 'icon', src: 'img/check-overlay.png')
          $icon.css('background-image', 'url(' + task.icon + ')')
        else
          $icon = $('<img>', class: 'icon', src: task.icon)
        $div.append($icon)

        $description = $('<span></span>', class: 'description')
        $description.text(task.description)
        $div.append($description)

        $('#taskList').append($div)
        $div.on('click', (event) -> window.location = task.url)
  )


# initialization
@initPage = ->
  tabcat.ui.requireUserAndEncounter()

  tabcat.ui.enableFastClick()

  $(->
    tabcat.ui.updateStatusBar()
    showTasks()
    $('#closeEncounter').on('click', tabcat.ui.closeEncounter)
    $('#closeEncounter').removeAttr('disabled')
    scrollTo(0, 1)
  )

  tabcat.db.startSpilledDocSync()
