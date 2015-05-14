# Description
#   A hubot script for reaping messages for slack
#
# Configuration:
#   SLACK_API_TOKEN		- Slack API Token (default. undefined )
#   TZ                - Timezone
#   HUBOT_SLACK_REAPER_SETTINGS - Set remote JSON file url includes target
#             channels with multiple patterns and durations.
#             For example:
#               { "channelRegExp1": { "patternRegExp1": duration1,
#                                     "patternRegExp2": duration2 },
#                 "channelRegExp2": { "patternRegExp3": duration3 } }
#
#   Unless set HUBOT_SLACK_REAPER_SETTINGS, use configurations as below
#   HUBOT_SLACK_REAPER_CHANNEL	- Target channel
#   			 	  (default. undefined i.e. all channels)
#   HUBOT_SLACK_REAPER_REGEX	- Target pattern (default. ".*")
#   HUBOT_SLACK_REAPER_DURATION	- Duration to reap in seconds (default. 300)
#
# Commands:
#   N/A
#
# Notes:
#   This hubot script removes every message, matched $HUBOT_SLACK_REAPER_REGEX,
#   posted into $HUBOT_SLACK_REAPER_CHANNEL in $HUBOT_SLACK_REAPER_DURATION
#   seconds after the post.
#
# Author:
#   Katsuyuki Tateishi <kt@wheel.jp>

cloneDeep = require 'lodash.clonedeep'
cronJob = require('cron').CronJob
time = require 'time'

apitoken = process.env.SLACK_API_TOKEN
timezone = process.env.TZ ? ""

module.exports = (robot) ->

  settings = undefined
  if process.env.HUBOT_SLACK_REAPER_SETTINGS
    url = process.env.HUBOT_SLACK_REAPER_SETTINGS
    robot.logger.info("Read json from:" + url)
    robot.http(url)
      .get() (err, resp, body) ->
        try
          settings = JSON.parse body
          robot.logger.info("settings:" + JSON.stringify settings)
        catch error
          robot.logger.error("JSON parse error")
  else
    targetroom = process.env.HUBOT_SLACK_REAPER_CHANNEL ? "^dev_null$"
    regex = process.env.HUBOT_SLACK_REAPER_REGEX ? ".*"
    duration = process.env.HUBOT_SLACK_REAPER_DURATION ? 300
    try
      settings = JSON.parse "{ \"#{targetroom}\": { \"#{regex}\": #{duration} } }"
      robot.logger.info("settings:" + JSON.stringify settings)
    catch error
      robot.logger.error("JSON parse error")

  data = {}
  room = {}
  report = []
  latestData = {}
  loaded = false

  robot.brain.on "loaded", ->
    # "loaded" event is called every time robot.brain changed
    # data loading is needed only once after a reboot
    if !loaded
      try
        data = JSON.parse robot.brain.get "hubot-slack-reaper-sumup"
        room = JSON.parse robot.brain.get "hubot-slack-reaper-room"
      catch error
        robot.logger.info("JSON parse error (reason: #{error})")
      latestData = cloneDeep data
    loaded = true

  sumUp = (channel, user) ->
    echannel = escape channel
    euser = escape user

    if !data
      data = {}
    if !data[echannel]
      data[echannel] = {}
    if !data[echannel][euser]
      data[echannel][euser] = 0
    data[echannel][euser]++
    robot.logger.info("sumUp:#{JSON.stringify(data)}")

    # wait robot.brain.set until loaded avoid destruction of data
    if loaded
      robot.brain.set "hubot-slack-reaper-sumup", JSON.stringify data

  score = (channel) ->
    echannel = escape channel

    # culculate diff between data[echannel] and latestData[echannel]
    diff = {}
    for name, num of data[echannel]
      if (num - latestData[echannel][name]) > 0
        diff[name] = num - latestData[echannel][name]

    # update latestData
    latestData = cloneDeep data

    # sort by deletions of diff
    z = []
    for k,v of diff
      z.push([k,v])
    z.sort( (a,b) -> b[1] - a[1] )

    # display ranking
    if z.length > 0
      msgs = [ "Deleted ranking of " + echannel ]
      for user in z
        msgs.push(user[0]+':'+user[1])
      return msgs.join("\n")
    return ""

  isInChannel = (channel) ->
    for roomRegExp, _ of settings
      if RegExp(roomRegExp).test(channel)
        return true
    return false

  getDeleteDuration = (channel, msg) ->
    durations = []
    for roomRegExp, patternRegExps of settings
      for msgRegExp, duration of patternRegExps
        if RegExp(roomRegExp).test(channel)
          if RegExp(msgRegExp).test(msg)
            durations.push(duration)
    return Math.min.apply 0, durations

  addRoom = (channel, setting, cron) ->
    channel = escape channel
    if !room
      room = {}
    if setting is "enable"
      # check cron pattern
      try
        new cronJob "0 " + cron, () ->
      catch error
        robot.logger.error("Invalid cron pattern:" + cron)
        return false
      room[channel] = cron
    else
      room[channel] = "disable"

    if loaded
      robot.brain.set "hubot-slack-reaper-room", JSON.stringify room
    return true

  enableReport = ->
    for job in report
      job.stop()
    report = []

    if loaded
      for channel, setting of room
        if setting isnt "disable"
          report[report.length] = new cronJob "0 " + setting, () ->
            robot.send { room: channel }, score(channel)
          , null, true, timezone
  enableReport()

  robot.hear /^report (enable|disable|list) *(\S+ \S+ \S+ \S+ \S+)*$/, (res) ->
    if res.match[1] is "enable" or res.match[1] is "disable"
      if addRoom(res.message.room, res.match[1], res.match[2])
        msg = res.match[1] + " score report of " + res.message.room + " " + res.match[2]
        robot.logger.info(msg)
        res.send msg
        enableReport()
      else
        res.send "Failed to change cron setting"
    else if res.match[1] is "list"
      res.send JSON.stringify room

  robot.hear /^score$/, (res) ->
    if not isInChannel(res.message.room)
      return
    reply = score(res.message.room)
    if reply.length > 0
      res.send reply

  robot.hear /^settings$/, (res) ->
    res.send "```" + JSON.stringify(settings) + "```"

  robot.hear /.*/, (res) ->
    if not isInChannel(res.message.room)
      return

    delDur = getDeleteDuration res.message.room, res.message.text

    if delDur isnt Infinity
      msgid = res.message.id
      channel = res.message.rawMessage.channel
      rmjob = ->
        echannel = escape(channel)
        emsgid = escape(msgid)
        eapitoken = escape(apitoken)
        robot.http("https://slack.com/api/chat.delete?token=#{eapitoken}&ts=#{emsgid}&channel=#{echannel}")
          .get() (err, resp, body) ->
            try
              json = JSON.parse(body)
              if json.ok
                robot.logger.info("Removed #{res.message.user.name}'s message \"#{res.message.text}\" in #{res.message.room}")
              else
                robot.logger.error("Failed to remove message")
            catch error
              robot.logger.error("Failed to request removing message #{msgid} in #{channel} (reason: #{error})")
      setTimeout(rmjob, duration * 1000)
      sumUp res.message.room, res.message.user.name.toLowerCase()
