###
Matcher/Parser helper for predicate and action strings
=================
###

__ = require("i18n").__
Promise = require 'bluebird'
S = require 'string'
assert = require 'cassert'
_ = require 'lodash'
milliseconds = require './milliseconds'


class Matcher

  # Some static helper
  comparators = {
    '==': ['equals', 'is equal to', 'is equal', 'is']
    '!=': [ 'is not', 'isnt' ]
    '<': ['less', 'lower', 'below']
    '>': ['greater', 'higher', 'above']
    '>=': ['greater or equal', 'higher or equal', 'above or equal',
           'equal or greater', 'equal or higher', 'equal or above']
    '<=': ['less or equal', 'lower or equal', 'below or equal',
           'equal or less', 'equal or lower', 'equal or below']
  }

  for sign in ['<', '>', '<=', '>=']
    comparators[sign] = _(comparators[sign]).map( 
      (c) => [c, "is #{c}", "is #{c} than", "is #{c} as", "#{c} than", "#{c} as"]
    ).flatten().value()

  for sign of comparators
    comparators[sign].push(sign)
  comparators['=='].push('=')

  normalizeComparator = (comparator) ->
    found = false
    for sign, c of comparators
      if comparator in c
        comparator = sign
        found = true
        break
    assert found
    return comparator


  # ###constructor()
  # Create a matcher for the input string, with the given parse context
  constructor: (@input, @context = null, @prevInput = "") ->

  
  # ###match()
  ###
  Matches the current inputs against the given pattern
  pattern can be an string, an regexp or an array of strings or regexps.
  If a callback is given it is called with a new Matcher for the remaining part of the string
  and the matching part of the input
  In addition a matcher is returned that hast the remaining parts as input.
  ###
  match: (patterns, options = {}, callback = null) ->
    unless @input? then return @
    unless Array.isArray patterns then patterns = [patterns]
    if typeof options is "function"
      callback = options
      options = {}

    matches = []

    for p, j in patterns
      # If pattern is a array then assume that first element is an id that should be returned
      # on match
      matchId = null
      if Array.isArray p
        assert p.length is 2
        [matchId, p] = p

      # handle ignore case for string
      [pT, inputT] = (
        if options.ignoreCase and typeof p is "string"
          [p.toLowerCase(), @input.toLowerCase()]
        else
          [p, @input]
      )

      # if pattern is an string, then we can add an autocomplete for it
      if typeof p is "string" and @context
        showAc = (if options.acFilter? then options.acFilter(p, j) else true) 
        if showAc
          if S(pT).startsWith(inputT) and @input.length < p.length
            @context?.addHint(autocomplete: p)

      # Now try to match the pattern against the input string
      doesMatch = false
      match = null
      nextToken = null
      switch 
        # do a normal string match
        when typeof p is "string" 
          doesMatch = S(inputT).startsWith(pT)
          if doesMatch 
            match = p
            nextToken = @input.substring(p.length)
        # do a regax match
        when p instanceof RegExp
          if options.ignoreCase?
            throw new new Error("ignoreCase option can't be used with regexp")
          regexpMatch = @input.match(p)
          if regexpMatch?
            doesMatch = yes
            match = regexpMatch[1]
            nextToken = regexpMatch[2]
        else throw new Error("Illegal object in patterns")

      if doesMatch
        assert match?
        assert nextToken?
        # If no matchId was provided then use the matching string itself
        unless matchId? then matchId = match
        matches.push {
          matchId
          match
          nextToken
        }
      
    nextInput = null
    match = null
    prevInputAndMatch = ""
    if matches.length > 0
      longestMatch = _(matches).sortBy( (m) => m.match.length ).last()
      nextInput = longestMatch.nextToken
      match = longestMatch.match
      prevInputAndMatch = @prevInput + match
      if callback?
        callback(
          M(nextInput, @context, prevInputAndMatch), 
          longestMatch.matchId
        )
    else if options.optional
      nextInput = @input
      prevInputAndMatch = @prevInput

    return M(nextInput, @context, prevInputAndMatch)

  # ###matchNumber()
  ###
  Matches any Number.
  ###
  matchNumber: (callback) -> 
    unless @input? then return @
    next = @match /^(-?[0-9]+\.?[0-9]*)(.*?)$/, callback


    showFormatHint = (@input is "" or next.input is "")

    if showFormatHint
      @context?.addHint(format: 'Number')
    return next

  matchVariable: (varsAndFuns, callback) -> 
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables} = varsAndFuns

    assert variables? and typeof variables is "object"
    assert typeof callback is "function"

    varsWithDollar = _(variables).keys().map( (v) => "$#{v}" ).valueOf()
    matches = []
    next = @match(varsWithDollar, (m, match) => matches.push([m, match]) )
    if matches.length > 0
      [next, match] = _(matches).sortBy( ([m, s]) => s.length ).last()
      callback(next, match)
    return next

  matchString: (callback) -> 
    unless @input? then return @
    ret = M(null, @context)
    @match('"').match(/^([^"]*)(.*?)$/, (m, str) =>
      ret = m.match('"', (m) => 
        callback(m, str)
      )
    )
    return ret

  matchOpenParenthese: (token, callback) ->
    unless @input? then return @
    tokens = []
    openedParentheseMatch = yes
    next = this
    while openedParentheseMatch
      m = next.match(token, (m) => 
        tokens.push token
        next = m.match(' ', optional: yes)
      )
      if m.hadNoMatch() then openedParentheseMatch = no
    if tokens.length > 0
      callback(next, tokens)
    return next

  matchCloseParenthese: (token, openedParentheseCount, callback) ->
    unless @input? then return @
    assert typeof openedParentheseCount is "number"
    tokens = []
    closeParentheseMatch = yes
    next = this
    while closeParentheseMatch and openedParentheseCount > 0
      m = next.match(' ', optional: yes).match(token, (m) => 
        tokens.push token
        openedParentheseCount--
        next = m
      )
      if m.hadNoMatch() then closeParentheseMatch = no
    if tokens.length > 0
      callback(next, tokens)
    return next

  matchFunctionCallArgs: (varsAndFuns, {funcName, argn}, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables, functions} = varsAndFuns
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"
    assert typeof callback is "function"

    tokens = []
    last = this

    hint = yes

    @matchAnyExpression(varsAndFuns, (next, ts) =>
      tokens = tokens.concat ts
      last = next
      next
        .match([',', ' , ', ' ,', ', '], {acFilter: (op) => op is ', '}, -> hint = false)
        .matchFunctionCallArgs(varsAndFuns, {funcName, argn: argn+1}, (m, ts) =>
          tokens.push ','
          tokens = tokens.concat ts
          last = m
        )
    )

    if hint and last.input is ""
      func = functions[funcName]
      if func.args?
        i = 0
        for argName, arg of func.args
          if arg.multiple?
            if argn > i
              @context?.addHint(format: argName)
            break
          if argn is i
            if arg.optional
              @context?.addHint(format: "[#{argName}]")
            else
              @context?.addHint(format: argName)
          i++

    callback(last, tokens)
    return last

  matchFunctionCall: (varsAndFuns, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables, functions} = varsAndFuns
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"
    assert typeof callback is "function"

    tokens = []
    last = null
    @match(_.keys(functions), (next, funcName) =>
      tokens.push funcName
      next.match(['(', ' (', ' ( ', '( '], {acFilter: (op) => op is '('}, (next) => 
        tokens.push '('
        next.matchFunctionCallArgs(varsAndFuns, {funcName, argn: 0}, (next, ts) =>
          tokens = tokens.concat ts
          next.match([')', ' )'], {acFilter: (op) => op is ')'},  (next) => 
            tokens.push ')'
            last = next
          )
        )
      )
    )
    if last?
      callback(last, tokens)
      return last
    else return M(null, @context)

  matchNumericExpression: (varsAndFuns, openParanteses = 0, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context
      openParanteses = 0
    
    {variables, functions} = varsAndFuns

    if typeof openParanteses is "function"
      callback = openParanteses
      openParanteses = 0

    assert callback? and typeof callback is "function"
    assert openParanteses? and typeof openParanteses is "number"
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"


    binarOps = ['+','-','*', '/']
    binarOpsFull = _(binarOps).map( (op)=>[op, " #{op} ", " #{op}", "#{op} "] ).flatten().valueOf()

    last = null
    tokens = []

    @matchOpenParenthese('(', (m, ptokens) =>
      tokens = tokens.concat ptokens
      openParanteses += ptokens.length
    ).or([
      ( (m) => m.matchNumber( (m, match) => tokens.push(parseFloat(match)); last = m ) ),
      ( (m) => m.matchVariable(varsAndFuns, (m, match) => tokens.push(match); last = m ) )
      ( (m) => m.matchFunctionCall(varsAndFuns, (m, match) => 
          tokens = tokens.concat match
          last = m
        )
      )
    ]).matchCloseParenthese(')', openParanteses, (m, ptokens) =>
      tokens = tokens.concat ptokens
      openParanteses -= ptokens.length
      last = m
    ).match(binarOpsFull, {acFilter: (op) => op[0] is ' ' and op[op.length-1] is ' '}, (m, op) => 
      m.matchNumericExpression(varsAndFuns, openParanteses, (m, nextTokens) => 
        tokens.push(op.trim())
        tokens = tokens.concat(nextTokens)
        last = m
      )
    )

    if last?
      callback(last, tokens)
      return last
    else return M(null, @context)

  matchStringWithVars: (varsAndFuns, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables, functions} = varsAndFuns
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"
    assert typeof callback is "function"

    last = null
    tokens = []

    next = @match('"')
    while next.hadMatch() and (not last?)
      next.match(/^([^"\$\{]*)(.*?)$/, (m, strPart) =>
        # strPart is string till first var or ending quote
        # Check for end:
        tokens.push('"' + strPart + '"')

        end = m.match('"')
        if end.hadMatch()  
          last = end
        # else test if it is a var
        else
          next = m.or([
            ( (m) => next = m.matchVariable(varsAndFuns, (m, match) => tokens.push(match) ); next ),
            ( (m) => 
              retMatcher = M(null, @context)
              m.match(['{', '{ '], {acFilter: (t)-> t is '{'}, (m, match) =>
                m.matchAnyExpression(varsAndFuns, (m, ts) =>
                  m.match(['}', ' }'], {acFilter: (t)-> t is '}'}, (m) =>
                    tokens.push '('
                    tokens = tokens.concat ts
                    tokens.push ')'
                    retMatcher = m
                  )
                )
              )
              return retMatcher
            )
          ])

      )
      
    if last?
      callback(last, tokens)
      return last
    else return M(null, @context)

  matchAnyExpression: (varsAndFuns, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables, functions} = varsAndFuns
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"
    assert typeof callback is "function"

    tokens = null
    next = @or([
      ( (m) => m.matchStringWithVars(varsAndFuns, (m, ts) => tokens = ts; return m) ),
      ( (m) => m.matchNumericExpression(varsAndFuns, (m, ts) => tokens = ts; return m) )
    ])
    if tokens?
      callback(next, tokens)
    return next

  matchComparator: (type, callback) ->
    unless @input? then return @
    assert type in ['number', 'string', 'boolean']
    assert typeof callback is "function"

    possibleComparators = (
      switch type
        when 'number' then _(comparators).values().flatten()
        when 'string', 'boolean' then _(comparators['=='].concat comparators['!='])
    ).map((c)=>" #{c} ").value()

    autocompleteFilter = (v) => 
      v.trim() in ['is', 'is not', 'equals', 'is greater than', 'is less than', 
        'is greater or equal than', 'is less or equal than', '<', '=', '>', '<=', '>=' 
      ]
    return @match(possibleComparators, acFilter: autocompleteFilter, ( (m, token) => 
      comparator = normalizeComparator(token.trim())
      return callback(m, comparator)
    ))


  # ###matchDevice()
  ###
  Matches any of the given devices.
  ###
  matchDevice: (devices, callback = null) ->
    unless @input? then return @
    devicesWithId = _(devices).map( (d) => [d, d.id] ).value()
    devicesWithNames = _(devices).map( (d) => [d, d.name] ).value() 

    matchingDevices = {}

    onIdMatch = (m, d) => matchingDevices[d.id] = {m, d}
    onNameMatch = (m, d) => matchingDevices[d.id] = {m, d}

    next = @match('the ', optional: true).or([
       # first try to match by id
      (m) => m.match(devicesWithId, onIdMatch)
      # then to try match names
      (m) => m.match(devicesWithNames, ignoreCase: yes, onNameMatch)
    ])
    for id, {m, d} of matchingDevices
      callback(m, d)
    return next
    
  matchTimeDurationExpression: (varsAndFuns, callback) ->
    unless @input? then return @

    if typeof varsAndFuns is "function"
      callback = varsAndFuns
      varsAndFuns = @context

    {variables, functions} = varsAndFuns
    assert variables? and typeof variables is "object"
    assert functions? and typeof functions is "object"
    assert typeof callback is "function"

    # Parse the for-Suffix:
    timeUnits = [
      "ms", 
      "second", "seconds", "s", 
      "minute", "minutes", "m", 
      "hour", "hours", "h", 
      "day", "days","d", 
      "year", "years", "y"
    ]
    tokens = 0
    unit = ""
    onTimeExpressionMatch = (m, ts) => tokens = ts  
    onMatchUnit = (m, u) => unit = u.trim()

    m = @matchNumericExpression(varsAndFuns, onTimeExpressionMatch).match(
      _(timeUnits).map((u) => [" #{u}", u]).flatten().valueOf()
    , {acFilter: (u) => u[0] is ' '}, onMatchUnit
    )

    if m.hadMatch()
      callback(m, {tokens, unit})
    return m


  matchTimeDuration: (options = null, callback) ->
    unless @input? then return @
    if typeof options is 'function'
      callback = options
      options = null

    # Parse the for-Suffix:
    timeUnits = [
      "ms", 
      "second", "seconds", "s", 
      "minute", "minutes", "m", 
      "hour", "hours", "h", 
      "day", "days","d", 
      "year", "years", "y"
    ]
    time = 0
    unit = ""
    onTimeMatch = (m, n) => time = parseFloat(n)
    onMatchUnit = (m, u) => unit = u

    m = @matchNumber(onTimeMatch).match(
      _(timeUnits).map((u) => [" #{u}", u]).flatten().valueOf()
    , {acFilter: (u) => u[0] is ' '}, onMatchUnit
    )

    if m.hadMatch()
      timeMs = milliseconds.parse "#{time} #{unit}"
      callback(m, {time, unit, timeMs})
    return m

  optional: (callback) ->
    unless @input? then return @
    next = callback(this)
    if next.hadMatch()
      return next
    else
      return this


  # ###onEnd()
  ###
  The given callback will be called for every empty string in the inputs of ther current matcher
  ###
  onEnd: (callback) ->
    if @input?.length is 0 then callback()

  # ###onHadMatches()
  ###
  The given callback will be called for every string in the inputs of ther current matcher
  ###
  ifhadMatches: (callback) ->
    if @input? then callback(@input)

  ###
    m.inAnyOrder([
      (m) => m.match(' title:').matchString(setTitle)
      (m) => m.match(' message:').matchString(setMessage)  
    ]).onEnd(...)
  ###

  inAnyOrder: (callbacks) ->
    assert Array.isArray callbacks
    hadMatch = yes
    current = this
    while hadMatch
      hadMatch = no
      for next in callbacks
        assert typeof next is "function"
        # try to match with this matcher
        m = next(current)
        assert m instanceof Matcher
        unless m.hadNoMatch()
          hadMatch = yes
          current = m
    return current

  or: (callbacks) ->
    assert Array.isArray callbacks
    matches = []
    for cb in callbacks
      m = cb(this)
      assert m instanceof Matcher
      matches.push m
    # Get the longest match
    next = _(matches).sortBy( (m) => 
      if m.input? then m.input.length else Number.MAX_VALUE
    ).first()
    return next

  hadNoMatch: -> not @input?
  hadMatch: -> @input?
  getFullMatch: -> @prevInput
  getRemainingInput: -> @input

  dump: (info) ->
    console.log(info + ":") if info? 
    console.log "prevInput: \"#{@prevInput}\" "
    console.log "input: \"#{@input}\""
    return @

M = (args...) -> new Matcher(args...)
M.createParseContext = (variables, functions)->
  return context = {
    autocomplete: []
    format: []
    errors: []
    warnings: []
    variables,
    functions
    addHint: ({autocomplete: a, format: f}) ->
      if a?
        if Array.isArray a 
          @autocomplete = @autocomplete.concat a
        else @autocomplete.push a
      if f?
        if Array.isArray f
          @format = @format.concat f
        else @format.push f
    addError: (message) -> @errors.push message
    addWarning: (message) -> @warnings.push message
    hasErrors: -> (@errors.length > 0)
    getErrorsAsString: -> _(@errors).reduce((ms, m) => "#{ms}, #{m}")
    finalize: () -> 
      @autocomplete = _(@autocomplete).uniq().sortBy((s)=>s.toLowerCase()).value()
      @format = _(@format).uniq().sortBy((s)=>s.toLowerCase()).value()
  }

module.exports = M
module.exports.Matcher = Matcher