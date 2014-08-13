# Represents and manages a game's state

_ = require('lodash')
uuid = require('uuid')
seed = require('seed-random')
math = require('mathjs')
deepcopy = require('deepcopy')

module.exports = class Game
    X_MAX: 25
    Y_MAX: 15
    DOTS_PER_PLAYER: 2
    FN_ANIMATION_SPEED: 0.005 # graph units per ms
    DOT_RADIUS: 1

    constructor: ->
      @subscriberIds = []
      @subscriberCallbacks = {}
      @playbackTime = Date.now()
      @lastFrameTime = null
      @animationRequestID = null
      @state = null
      @data =
        rand: Math.random()
        moves: []

    ##########################
    # Moves / state generation
    ##########################

    pushMove: (move, agentId, time) ->
      move.t = time || Date.now()
      move.agentId = agentId
      @data.moves.push(move)
      @_dataUpdateAll()

    # Add a player (with given id and name) to the team with fewer players.
    # Only the server can issue this move.
    @addPlayer: (playerId, playerName) ->
      return {type: 'addPlayer', playerId: playerId, playerName: playerName}

    # Remove the player with the given id from the game if he exists.
    # Players can only remove themselves.
    @removePlayer: (playerId) ->
      return {type: 'removePlayer', playerId: playerId}

    # Start the game on behalf of the player with the given id.
    # Only the server can issue this move, and only on behalf of a player
    # in the game. The game must not already have been started.
    @start: (playerId)->
      return {type: 'start', playerId: playerId}

    # Fire the given function from the currently active dot. Only the currently
    # active player can issue this move.
    @fire: (expression) ->
      return {type: 'fire', expression: expression}

    generateStateAtTimeForPlayer: (t, playerId) ->
      # If @state and t >= @state.time, we can start from there. Otherwise
      # we need to replay from the beginning.
      unless @state and t >= @state.time and playerId == @state.playerId
        @state = 
          playerId: playerId
          time: -1
          teams: [
              active: true
              players: []
            ,
              active: false
              players: []
          ]
          started: false

      while @state.time < t
        nextMove = _.find(@data.moves, (m) => m.t > @state.time)
        dt = (if nextMove then Math.min(nextMove.t, t) else t) - @state.time
        @state.time += dt

        @_processCollisions(@state, dt) if @state.fn

        # Apply move (if any) at t
        if nextMove?.t == @state.time
          switch nextMove.type
            when 'addPlayer'    then @_addPlayer(@state, nextMove)
            when 'removePlayer' then @_removePlayer(@state, nextMove)
            when 'start'        then @_start(@state, nextMove)
            when 'fire'         then @_fire(@state, nextMove)

      return @state

    #########
    # Players
    #########

    _addPlayer: (state, move) ->
      return if state.started or move.agentId?

      if state.teams[0].players.length <= state.teams[1].players.length
        team = state.teams[0]
      else
        team = state.teams[1]

      team.players.push {
        id: move.playerId,
        name: move.playerName,
        active: false
        dots: []
      }

    _removePlayer: (state, move) ->
      return unless move.agentId == move.playerId
      for team in state.teams
        team.players = _.reject(team.players, (p) -> p.id == move.id)

    # Return the player with the given id, or undefined if none exists.
    _getPlayer: (state, id) ->
      players = _.flatten(_.pluck(state.teams, 'players'))
      _.find(players, (p) -> p.id == id)

    ##########
    # Gameplay
    ##########

    _start: (state, move) ->
      return if move.agentId? or 
                !@_getPlayer(state, move.playerId) or 
                state.started

      state.started = true
      @_generateInitialPositions(state)

      state.teams[0].active = true
      state.teams[0].players[0].active = true
      state.teams[0].players[0].dots[0].active = true

      for team, index in state.teams
        for player in team.players
          if (player.id == state.playerId)
            state.flipped = index > 0

    _dist: (point1, point2) ->
      Math.sqrt(
        Math.pow(point2.x - point1.x, 2) +
        Math.pow(point2.y - point1.y, 2)
      )

    # Populate players with randomly positioned dots
    _generateInitialPositions: (state) ->
      rand = seed(@data.rand)

      randomPoint = (x0, y0, width, height) ->
        x: (rand() * width) + x0
        y: (rand() * height) + y0

      # Keep track of generated dots to avoid generating two nearby dots
      dots = []

      for team, teamIndex in state.teams
        hOffset = (teamIndex-1) * (@X_MAX)
        for player in team.players
          for i in [1..@DOTS_PER_PLAYER]
            until dot? && dots.every((d)=> @_dist(dot,d) > 4)
              dot = randomPoint(
                hOffset, 
                -@Y_MAX, 
                @X_MAX, 
                @Y_MAX*2
              )
            dot.alive = true
            dot.active = false
            dots.push(dot)
            player.dots.push(dot)

    # # Advance the game by one turn, updating team/player/dot active values
    # advanceTurn: ->
    #   recursivelyAdvance = (ary) ->
    #     return unless ary?
    #     for item,i in ary
    #       if item.active
    #         item.active = false
    #         ary[(i+1) % ary.length].active = true
    #         recursivelyAdvance(item.players || item.dots || null)
    #         break
    #   recursivelyAdvance(@state.teams)

    # #attempt to make a move as the player, validate
    # moveAsPlayer: (id, move)->
    #   if validateMoveAsPlayer(id, move)
    #     getActiveDotForPlayer(id).push(move)

    # #validate whether the player is active and can make the proposed move
    # validateMoveAsPlayer: (id, move) ->
    #   player = getPlayer(id)
    #   player.active && player.team.active

    # Get the active team, player, and dot.
    _getActive: (state) ->
      team = _.find(state.teams, (x) -> x.active)
      player = _.find(team.players, (x) -> x.active)
      dot = _.find(player.dots, (x) -> x.active)
      {team, player, dot}

    _fire: (state, move) ->
      active = @_getActive(state)
      return unless move.agentId == active.player.id

      compiledFunction = math.compile(move.expression)
      state.fn = {
        expression: move.expression,
        evaluate: (x) -> compiledFunction.eval(x: x - active.dot.x) - compiledFunction.eval(x: 0) + active.dot.y,
        origin: {x: active.dot.x, y: active.dot.y},
        startTime: state.time
      }

    _processCollisions: (state, dt) ->
      # Don't process collisions for times before the function was fired
      dt = Math.min(dt, state.time - state.fn.startTime)

      x0 = state.fn.origin.x + @FN_ANIMATION_SPEED*((state.time-dt)-state.fn.startTime)
      xMax = state.fn.origin.x + @FN_ANIMATION_SPEED*(state.time-state.fn.startTime)
      dx = 0.05

      active = @_getActive(state)
      for x in [x0 .. xMax] by dx
        y = state.fn.evaluate(x)

        for team in state.teams
          for player in team.players
            for dot, index in player.dots
              if dot != active.dot and @_dist({x,y}, dot) < @DOT_RADIUS
                player.dots[index].alive = false

      delete state.fn if xMax >= @X_MAX

    ######################
    # Sync / subscriptions
    ######################

    # Update the game data. Use this to synchronize
    # with another Game object.
    replaceData: (newData) ->
      @data = newData
      @state = null
      @playbackTime = @data.currentTime

    # Call the given callback whenever the game data changes, passing the
    # new game data as an argument. Accepts an id which you can pass to
    # unsubscribe if you want to stop the callbacks.
    dataSubscribe: (id, callback) ->
      return if _.contains(@subscriberIds, id)
      @subscriberIds.push(id)
      @subscriberCallbacks[id] = callback
      @_dataUpdate(id)

    # Stop calling the callback passed to subscribe with the given id.
    dataUnsubscribe: (id) ->
      @subscriberIds = _.without(@subscriberIds, id)
      delete @subscriberCallbacks[id] if @subscriberCallbacks[id]

    # Fire all the subscribed callbacks.
    _dataUpdateAll: ->
      for id in @subscriberIds
        @_dataUpdate(id)

    # Fire the subscribed callback with the given id only.
    _dataUpdate: (subscriberId) ->
      _.extend(@data, currentTime: Date.now())
      @subscriberCallbacks[subscriberId](@data)

    # Start animating, calling callback with a game state object every frame.
    startAnimatingForPlayer: (playerId, callback) ->
      animate = (t) =>
        @playbackTime += (t - @lastFrameTime)
        @lastFrameTime = t
        callback(@generateStateAtTimeForPlayer(@playbackTime, playerId))
        @animationRequestID = requestAnimationFrame(animate)
      @animationRequestID = requestAnimationFrame(animate)

    stopAnimating: ->
      cancelAnimationFrame(@animationRequestID)
      @animationRequestID = null