_ = window?._ ? self?._ ? global?._ ? require 'lodash'  # rely on lodash existing, since it busts CodeCombat to browserify it--TODO

S = require('esprima').Syntax
SourceMap = require 'source-map'

ranges = require './ranges'
{commonMethods} = require './problems'

statements = [S.EmptyStatement, S.ExpressionStatement, S.BreakStatement, S.ContinueStatement, S.DebuggerStatement, S.DoWhileStatement, S.ForStatement, S.FunctionDeclaration, S.ClassDeclaration, S.IfStatement, S.ReturnStatement, S.SwitchStatement, S.ThrowStatement, S.TryStatement, S.VariableStatement, S.WhileStatement, S.WithStatement, S.VariableDeclaration]

getParents = (node) ->
  parents = []
  while node.parent
    parents.push node = node.parent
  parents

getParentsOfTypes = (node, types) ->
  _.filter getParents(node), (elem) -> elem.type in types

getFunctionNestingLevel = (node) ->
  getParentsOfTypes(node, [S.FunctionExpression]).length

possiblyGeneratorifyAncestorFunction = (node) ->
  while node.type isnt S.FunctionExpression
    node = node.parent
  node.mustBecomeGeneratorFunction = true

possiblyGeneratorifyUserFunction = (fnExpr, node) ->
  # Look for a CallExpression in fnExpr, that isn't in an inner function
  node = fnExpr unless node
  for key, child of node
    continue if key is 'parent' or key is 'leadingComments' or key is 'originalNode'
    if child?.type is S.ExpressionStatement and child.expression.right?.type is S.CallExpression
      return fnExpr.mustBecomeGeneratorFunction = true
    else if child?.type is S.FunctionExpression 
      continue
    else if _.isArray child
      for grandchild in child
        if _.isString grandchild?.type
          if grandchild?.type is S.ExpressionStatement and grandchild.expression?.right?.type is S.CallExpression
            return fnExpr.mustBecomeGeneratorFunction = true
          continue if grandchild?.type is S.FunctionExpression
          return true if possiblyGeneratorifyUserFunction fnExpr, grandchild
    else if _.isString child?.type
      return true if possiblyGeneratorifyUserFunction fnExpr, child
  false

getUserFnMap = (startNode) ->
  # Return map of CallExpressions to user defined FunctionExpressions
  # Parses whole AST, given any startNode in user code
  # Assumes normalized AST, and morphAST helpers
  # Ideally called only once per unique user code
  # High level steps:
  # 1. Build a scope hierarchy of calls, functions, and variable mappings
  # 2. Resolve all user FunctionExpression assignments to outermost value
  # 3. Resolve all CallExpressions to outermost value
  # 4. Match each CallExpression to a FunctionExpression, if possible
  
  # TODO: Handle calling an inner function returned from another function
  # TODO: We're doing unnecessary work in favor of simplicity

  ## Helpers

  parseVal = (node) ->
    if node?.type is S.Literal 
      return node.value 
    else if node?.type is S.Identifier 
      return node.name 
    else if node?.type is S.ThisExpression 
      return 'this' 
    else if node?.type is S.MemberExpression
      return [node.object.name, node.property.name] if node.object?.name? and node.property?.name?

  updateVal = (val, left, right) ->
    # Update val based on a 'left = right' assignment
    if _.isArray val
      for j in [0..val.length-1]
        if left is val[j]
          if _.isArray right 
            val.splice.apply val, [j, 1].concat right
          else 
            val[j] = right
        else if right is val[j] and _.isArray left
          if _.isArray left 
            val.splice.apply val, [j, 1].concat left
          else 
            val[j] = left
    else
      if left is val 
        val = right
      else if right is val and _.isArray left 
        val = left
    val

  getRootScope = ->
    # A scope here is a flattened variable map, call map, and immediate children scopes
    # Scope.current is the scope container, always a FunctionExpression currently

    buildVarMap = (varMap, node) ->
      if node?.type is S.ExpressionStatement and node.expression?.type is S.AssignmentExpression
        vLeft = parseVal(node.expression.left)
        vRight = parseVal(node.expression.right)
        varMap.push [vLeft, vRight] if vLeft and vRight
      for key, child of node
        continue if key is 'parent' or key is 'leadingComments' or key is 'originalNode'
        continue if child?.type is S.FunctionExpression
        if _.isArray child
          for grandchild in child
            buildVarMap varMap, grandchild if _.isString grandchild?.type
        else if _.isString child?.type
          buildVarMap varMap, child

    buildCallMap = (calls, node) ->
      if node?.type is S.ExpressionStatement and node.expression?.type is S.AssignmentExpression
        calls.push node.expression if node.expression.right?.type is S.CallExpression

      for key, child of node
        continue if key is 'parent' or key is 'leadingComments' or key is 'originalNode'
        continue if child?.type is S.FunctionExpression
        if _.isArray child
          for grandchild in child
            buildCallMap calls, grandchild if _.isString grandchild?.type
        else if _.isString child?.type
          buildCallMap calls, child

    buildScope = (scope, fn) ->
      # Use fn to fill out scope.children, scope.varMap, scope.calls
      # Scope.parent, and scope.current are filled out by caller
      buildVarMap scope.varMap, fn
      buildCallMap scope.calls, fn

      if fn.body?.body?
        for key, child of fn.body.body
          continue if key is 'parent' or key is 'leadingComments' or key is 'originalNode'
          if child?.type is S.ExpressionStatement and child.expression?.type is S.AssignmentExpression
            if child.expression.right?.type is S.FunctionExpression
              childScope = {
                children: []
                varMap: []
                calls: []
                parent: scope
                current: child.expression
              }
              buildScope childScope, child.expression.right
              scope.children.push childScope

    wrapperFn = startNode
    while wrapperFn and (wrapperFn.type isnt S.FunctionExpression or getFunctionNestingLevel(wrapperFn) > 1)
      wrapperFn = wrapperFn.parent

    scope = {
      children: []
      varMap: []
      calls: []
      parent: null
      current: null
    }
    buildScope scope, wrapperFn if wrapperFn
    scope

  findCall = (scope, fnVal) ->
    # Find a CallExpression that resolves to fnVal
    return [null, null] unless fnVal
    for c in scope.calls
      cVal = parseVal c.right.callee
      cVal = resolveVal scope, scope.varMap, cVal
      return [scope, c.right] if _.isEqual(cVal, fnVal)
    for childScope in scope.children
      if childScope.current
        childFn = parseVal childScope.current.left
        if childFn isnt fnVal
          return call if call = findCall childScope, fnVal
    [null, null]

  resolveVal = (scope, vm, val) ->
    # Resolve value based on assignments in this scope
    # E.g. a = tmp1; tmp1 = tmp2; resolveVal(tmp2) resturns 'a'
    return unless val
    # Look locally
    if vm.length > 0
      for i in [vm.length-1..0]
        val = updateVal val, vm[i][0], vm[i][1]
    # Look in params if in a function
    if scope.current?.right?.type is S.FunctionExpression and scope.current.right.params.length > 0
      for i in [0..scope.current.right.params.length-1]
        pVal = parseVal scope.current.right.params[i]
        if (_.isArray val) and val[0] is pVal or val is pVal
          fnVal = parseVal scope.current.left
          fnVal = resolveVal scope, scope.varMap, fnVal
          [newScope, callExpr] = findCall rootScope, fnVal
          if newScope and callExpr
            # Update val based on passed in argument, and resolve from new scope
            argVal = parseVal callExpr.arguments[i]
            if _.isArray val
              val[0] = argVal
            else
              val = argVal
            val = resolveVal newScope, newScope.varMap, val
          break
    # Look in parent
    val = resolveVal scope.parent, scope.parent.varMap, val if scope.parent
    val

  resolveFunctions = (scope, fns) ->
    # Resolve all FunctionExpression nodes
    if scope?.current?.right?.type is S.FunctionExpression
      fnVal = parseVal scope.current.left
      fnVal = resolveVal scope, scope.varMap, fnVal
      fns.push [scope.current.right, fnVal]
    resolveFunctions childScope, fns for childScope in scope.children

  resolveCalls = (scope, calls) ->
    # Resolve all CallExpression nodes
    for call in scope.calls
      val = parseVal call.right.callee
      val = resolveVal scope, scope.varMap, val
      calls.push [call.right, val]
    resolveCalls childScope, calls for childScope in scope.children

  ## End helpers

  userFnMap = []
  try
    rootScope = getRootScope()

    resolvedFunctions = []
    resolveFunctions rootScope, resolvedFunctions
    #console.log 'resolvedFunctions', resolvedFunctions

    resolvedCalls = []
    resolveCalls rootScope, resolvedCalls
    #console.log 'resolvedCalls', resolvedCalls

    for [call, callVal] in resolvedCalls
      for [fn, fnVal] in resolvedFunctions
        if _.isEqual(callVal, fnVal)
          userFnMap.push [call, fn]
          break
        else if (_.isArray callVal) and callVal[0] is fnVal
          userFnMap.push [call, fn]
          break
    #console.log 'userFnMap', userFnMap
  catch error
    console.log 'ERROR in transforms.getUserFnMap', error
  userFnMap

getUserFnExpr = (userFnMap, callExpr) ->
  if userFnMap
    for [call, fn] in userFnMap
      return fn if callExpr is call

########## Before JS_WALA Normalization ##########

# Original node range preservation.
# 1. Make a many-to-one mapping of normalized nodes to original nodes based on the original ranges, which are unique except for the outer Program wrapper.
# 2. When we generate the normalizedCode, we can also create a source map.
# 3. A postNormalizationTransform can then get the original ranges for each node by going through the source map to our normalized mapping to our original node ranges.
# 4. Instrumentation can then include the original ranges and node source in the saved flow state.
module.exports.makeGatherNodeRanges = makeGatherNodeRanges = (nodeRanges, code, codePrefix) -> (node) ->
  return unless node.range
  node.originalRange = ranges.offsetsToRange node.range[0], node.range[1], code, codePrefix
  node.originalSource = node.source()
  nodeRanges.push node

# Making
module.exports.makeCheckThisKeywords = makeCheckThisKeywords = (globals, varNames) ->
  return (node) ->
    if node.type is S.VariableDeclarator
      varNames[node.id.name] = true
    else if node.type is S.AssignmentExpression
      varNames[node.left.name] = true
    else if node.type is S.FunctionDeclaration or node.type is S.FunctionExpression# and node.parent.type isnt S.Program
      varNames[node.id.name] = true if node.id?
      varNames[param.name] = true for param in node.params
    else if node.type is S.CallExpression
      # TODO: false negative when user method call precedes function declaration
      v = node
      while v.type in [S.CallExpression, S.MemberExpression]
        v = if v.object? then v.object else v.callee
      v = v.name
      if v and not varNames[v] and not (v in globals)
        # Probably MissingThis, but let's check if we're recursively calling an inner function from itself first.
        for p in getParentsOfTypes node, [S.FunctionDeclaration, S.FunctionExpression, S.VariableDeclarator, S.AssignmentExpression]
          varNames[p.id.name] = true if p.id?
          varNames[p.left.name] = true if p.left?
          varNames[param.name] = true for param in p.params if p.params?
          return if varNames[v] is true
        # TODO: we need to know whether `this` has this method before saying this...
        message = "Missing `this.` keyword; should be `this.#{v}`."
        hint = "There is no function `#{v}`, but `this` has a method `#{v}`."
        range = [node.originalRange.start, node.originalRange.end]
        problem = @createUserCodeProblem type: 'transpile', reporter: 'aether', kind: 'MissingThis', message: message, hint: hint, range: range  # TODO: code/codePrefix?
        @addProblem problem

module.exports.checkIncompleteMembers = checkIncompleteMembers = (node) ->
  #console.log 'check incomplete members', node, node.source() if node.source().search('this.') isnt -1
  if node.type is 'ExpressionStatement'
    exp = node.expression
    if exp.type is 'MemberExpression'
      # Handle missing parentheses, like in:  this.moveUp;
      if exp.property.name is "IncompleteThisReference"
        kind = 'IncompleteThis'
        m = "this.what? (Check available spells below.)"
        hint = ''
      else
        kind = 'NoEffect'
        m = "#{exp.source()} has no effect."
        if exp.property.name in commonMethods
          m += " It needs parentheses: #{exp.source()}()"
        else
          hint = "Is it a method? Those need parentheses: #{exp.source()}()"
      problem = @createUserCodeProblem type: 'transpile', reporter: 'aether', message: m, kind: kind, hint: hint, range: if node.originalRange then [node.originalRange.start, node.originalRange.end] else null  # TODO: code/codePrefix?
      @addProblem problem

########## After JS_WALA Normalization ##########

# Restoration of original nodes after normalization
module.exports.makeFindOriginalNodes = makeFindOriginalNodes = (originalNodes, codePrefix, normalizedSourceMap, normalizedNodeIndex) ->
  normalizedPosToOriginalNode = (pos) ->
    start = pos.start_offset - codePrefix.length
    end = pos.end_offset - codePrefix.length
    return node for node in originalNodes when start is node.originalRange.start.ofs and end is node.originalRange.end.ofs
    return null
  smc = new SourceMap.SourceMapConsumer normalizedSourceMap.toString()
  #console.log "Got smc", smc, "from map", normalizedSourceMap, "string", normalizedSourceMap.toString()
  return (node) ->
    return unless mapped = smc.originalPositionFor line: node.loc.start.line, column: node.loc.start.column
    #console.log "Got normalized position", mapped, "for node", node, node.source()
    return unless normalizedNode = normalizedNodeIndex[mapped.column]
    #console.log "  Got normalized node", normalizedNode
    node.originalNode = normalizedPosToOriginalNode normalizedNode.attr.pos
    #console.log "  Got original node", node.originalNode, "from pos", normalizedNode.attr?.pos

# Now that it's normalized to this: https://github.com/nwinter/JS_WALA/blob/master/normalizer/doc/normalization.md
# ... we can basically just put a yield check in after every CallExpression except the outermost one if we are yielding conditionally.
module.exports.makeYieldConditionally = makeYieldConditionally = ->
  userFnMap = null
  return (node) ->
    if node.type is S.ExpressionStatement and node.expression.right?.type is S.CallExpression
      # Because we have a wrapper function which shouldn't yield, we only yield inside nested functions.
      # Don't yield after calls to generatorified inner functions, because their yields are passed upwards
      return unless getFunctionNestingLevel(node) > 1
      userFnMap = getUserFnMap(node) unless userFnMap
      unless getUserFnExpr(userFnMap, node.expression.right)?.mustBecomeGeneratorFunction
        node.update "#{node.source()} if (_aether._shouldYield) { var _yieldValue = _aether._shouldYield; _aether._shouldYield = false; yield _yieldValue; }"
      node.yields = true
      possiblyGeneratorifyAncestorFunction node unless node.mustBecomeGeneratorFunction
    else if node.mustBecomeGeneratorFunction
      node.update node.source().replace /^function \(/, 'function* ('
    else if node.type is S.AssignmentExpression and node.right?.type is S.CallExpression
      # Update call to generatorified user function to process yields, and set return result
      userFnMap = getUserFnMap(node) unless userFnMap
      if (fnExpr = getUserFnExpr(userFnMap, node.right)) and possiblyGeneratorifyUserFunction fnExpr
        node.update "var __gen#{node.left.source()} = #{node.right.source()}; while (true) { var __result#{node.left.source()} = __gen#{node.left.source()}.next(); if (__result#{node.left.source()}.done) { #{node.left.source()} = __result#{node.left.source()}.value; break; } yield __result#{node.left.source()}.value;}"

module.exports.makeYieldAutomatically = makeYieldAutomatically = ->
  userFnMap = null
  return (node) ->
    # TODO: don't yield after things like 'use strict';
    # TODO: think about only doing this after some of the statements which have a different original range?
    if node.type in statements
      # Because we have a wrapper function which shouldn't yield, we only yield inside nested functions.
      # Don't yield after calls to generatorified inner functions, because their yields are passed upwards
      return unless getFunctionNestingLevel(node) > 1
      if node.type is S.ExpressionStatement and node.expression.right?.type is S.CallExpression
        userFnMap = getUserFnMap(node) unless userFnMap
        unless getUserFnExpr(userFnMap, node.expression.right)?.mustBecomeGeneratorFunction
          node.update "#{node.source()} yield 'waiting...';"
      else
        node.update "#{node.source()} yield 'waiting...';"
      node.yields = true
      possiblyGeneratorifyAncestorFunction node unless node.mustBecomeGeneratorFunction
    else if node.mustBecomeGeneratorFunction
      node.update node.source().replace /^function \(/, 'function* ('
    else if node.type is S.AssignmentExpression and node.right?.type is S.CallExpression
      # Update call to generatorified user function to process yields, and set return result
      userFnMap = getUserFnMap(node) unless userFnMap
      if (fnExpr = getUserFnExpr(userFnMap, node.right)) and possiblyGeneratorifyUserFunction fnExpr
        node.update "var __gen#{node.left.source()} = #{node.right.source()}; while (true) { var __result#{node.left.source()} = __gen#{node.left.source()}.next(); if (__result#{node.left.source()}.done) { #{node.left.source()} = __result#{node.left.source()}.value; break; } yield __result#{node.left.source()}.value;}"

module.exports.makeInstrumentStatements = makeInstrumentStatements = (varNames) ->
  # set up any state tracking here
  return (node) ->
    orig = node.originalNode
    #console.log "Should we instrument", orig?.originalSource, node.source(), node, "?", (orig and orig.originalRange.start >= 0), (node.type in statements), orig?.type, getFunctionNestingLevel(node) if node.source().length < 50
    return unless orig and orig.originalRange.start.ofs >= 0
    return unless node.type in statements
    return if orig.type in [S.ThisExpression, S.Identifier]  # probably need to add to this to get statements which corresponded to interesting expressions before normalization
    # Only do this in nested functions, not our wrapper
    return unless getFunctionNestingLevel(node) > 1
    if orig.parent?.type is S.AssignmentExpression and orig.parent.parent?.type is S.ExpressionStatement and orig.parent.parent.originalRange
      orig = orig.parent.parent
    else if orig.parent?.type is S.VariableDeclarator and orig.parent.parent?.type is S.VariableDeclaration and orig.parent.parent.originalRange
      orig = orig.parent.parent
    # TODO: actually save this into aether.flow, and have it happen before the yield happens
    safeRange = ranges.stringifyRange orig.originalRange.start, orig.originalRange.end
    prefix = "_aether.logStatementStart(#{safeRange});"
    if varNames
      loggers = ("_aether.vars['#{varName}'] = typeof #{varName} == 'undefined' ? undefined : #{varName};" for varName of varNames)
      logging = " if (!_aether._shouldSkipFlow) { #{loggers.join ' '} }"
    else
      logging = ''
    suffix = " _aether.logStatement(#{safeRange}, _aether._userInfo, #{if varNames then '!_aether._shouldSkipFlow' else 'false'});"
    node.update "#{prefix} #{node.source()} #{logging}#{suffix}"
    #console.log " ... created logger", node.source(), orig

module.exports.interceptThis = interceptThis = (node) ->
  return unless node.type is S.ThisExpression
  return unless getFunctionNestingLevel(node) > 1
  node.update "__interceptThis(this, __global)"

module.exports.interceptEval = interceptEval = (node) ->
  return unless node.type is S.Identifier and node.name is 'eval'
  node.update "evil"

module.exports.makeInstrumentCalls = makeInstrumentCalls = (varNames) ->
  # set up any state tracking here
  return (node) ->
    # Don't do this if it's an inner function they defined
    return unless getFunctionNestingLevel(node) is 2
    if node.type is S.ReturnStatement
      node.update "_aether.logCallEnd(); #{node.source()}"
    # Look at the top variable declaration inside our appropriately nested function to see where the call starts
    return unless node.type is S.VariableDeclaration
    node.update "'use strict'; _aether.logCallStart(_aether._userInfo); #{node.source()}"  # TODO: pull in arguments?

module.exports.protectAPI = (node) ->
  return unless node.type in [S.CallExpression, S.ThisExpression, S.VariableDeclaration, S.ReturnStatement]
  level = getFunctionNestingLevel node
  return unless level > 1

  # Restore clones when passing to functions or returning them.
  if node.type is S.CallExpression
    for arg in node.arguments
      arg.update "_aether.restoreAPIClone(_aether, #{arg.source()})"
  else if node.type is S.ReturnStatement and arg = node.argument
    arg.update "_aether.restoreAPIClone(_aether, #{arg.source()})"

  # Create clones from arguments and function return values.
  if node.parent.type is S.AssignmentExpression or node.type is S.ThisExpression
    node.update "_aether.createAPIClone(_aether, #{node.source()})"
  else if node.type is S.VariableDeclaration
    parameters = (param.name for param in (node.parent.parent.params ? []))
    protectors = ("#{parameter} = _aether.createAPIClone(_aether, #{parameter});" for parameter in parameters)
    argumentsProtector = "for(var __argIndexer = 0; __argIndexer < arguments.length; ++__argIndexer) arguments[__argIndexer] = _aether.createAPIClone(_aether, arguments[__argIndexer]);"
    node.update "#{node.source()} #{protectors.join ' '} #{argumentsProtector}"
    #console.log "variable declaration #{node.source()} grandparent is", node.parent.parent

  #console.log "protectAPI?", node, node.source()
