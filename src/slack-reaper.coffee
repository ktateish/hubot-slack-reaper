# Description
#   A hubot script for reaping messages for slack
#
# Configuration:
#   SLACK_API_TOKEN		- Slack API Token (default. undefined )
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

targetroom = process.env.HUBOT_SLACK_REAPER_CHANNEL
regex = new RegExp(process.env.HUBOT_SLACK_REAPER_REGEX ? ".*")
duration = process.env.HUBOT_SLACK_REAPER_DURATION ? 300
apitoken = process.env.SLACK_API_TOKEN

module.exports = (robot) ->

  data = {}
  latestData = {}
  loaded = false

  robot.brain.on "loaded", ->
    # "loaded" event is called every time robot.brain changed
    # data loading is needed only once after a reboot
    if !loaded
      try
        data = JSON.parse robot.brain.get "hubot-slack-reaper-sumup"
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

  robot.hear /^score$/, (res) ->
    if targetroom
      if res.message.room != targetroom
        return
    reply = score(res.message.room)
    if reply.length > 0
      res.send reply

  robot.hear regex, (res) ->
    if targetroom
      if res.message.room != targetroom
        return
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
