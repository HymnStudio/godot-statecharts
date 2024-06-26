@icon("state_chart.svg")
@tool
## This is statechart. It contains a root state (commonly a compound or parallel state) and is the entry point for 
## the state machine.
class_name StateChart 
extends Node

## The the remote debugger
const DebuggerRemote = preload("utilities/editor_debugger/editor_debugger_remote.gd")

## Emitted when the state chart receives an event. This will be 
## emitted no matter which state is currently active and can be 
## useful to trigger additional logic elsewhere in the game 
## without having to create a custom event bus. It is also used
## by the state chart debugger. Note that this will emit the 
## events in the order in which they are processed, which may 
## be different from the order in which they were received. This is
## because the state chart will always finish processing one event
## fully before processing the next. If an event is received
## while another is still processing, it will be enqueued.
signal event_received(event:StringName)

## Flag indicating if this state chart should be tracked by the 
## state chart debugger in the editor.
@export var track_in_editor:bool = false

## The root state of the state chart.
var _state:State = null

## This dictonary contains known properties used in expression guards. Use the 
## [method set_expression_property] to add properties to this dictionary.
var _expression_properties:Dictionary = {
}

## A list of pending events 
var _queued_events:Array[StringName] = []

## Whether or not a property change is pending.
var _property_change_pending:bool = false

## Flag indicating if the state chart is currently processing. 
## Until a change is fully processed, no further changes can
## be introduced from the outside.
var _locked_down:bool = false

var _queued_transitions:Array[Dictionary] = []
var _transitions_processing_active:bool = false

var _debugger_remote:DebuggerRemote = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return 

	# check if we have exactly one child that is a state
	if get_child_count() != 1:
		push_error("StateChart must have exactly one child")
		return

	# check if the child is a state
	var child:Node = get_child(0)
	if not child is State:
		push_error("StateMachine's child must be a State")
		return

	# initialize the state machine
	_state = child as State
	_state._state_init()

	# enter the state
	_state._state_enter.call_deferred()

	# if we are in an editor build and this chart should be tracked 
	# by the debugger, create a debugger remote
	if track_in_editor and OS.has_feature("editor"):
		_debugger_remote = DebuggerRemote.new(self)


## Sends an event to this state chart. The event will be passed to the innermost active state first and
## is then moving up in the tree until it is consumed. Events will trigger transitions and actions via emitted
## signals. There is no guarantee when the event will be processed. The state chart
## will process the event as soon as possible but there is no guarantee that the 
## event will be fully processed when this method returns.
func send_event(event:StringName) -> void:
	if not is_node_ready():
		push_error("State chart is not yet ready. If you call `send_event` in _ready, please call it deferred, e.g. `state_chart.send_event.call_deferred(\"my_event\").")
		return
		
	if not is_instance_valid(_state):
		push_error("State chart has no root state. Ignoring call to `send_event`.")
		return
	
	_queued_events.append(event)
	_run_changes()
		
		
## Sets a property that can be used in expression guards. The property will be available as a global variable
## with the same name. E.g. if you set the property "foo" to 42, you can use the expression "foo == 42" in
## an expression guard.
func set_expression_property(name:StringName, value) -> void:
	if not is_node_ready():
		push_error("State chart is not yet ready. If you call `set_expression_property` in `_ready`, please call it deferred, e.g. `state_chart.set_expression_property.call_deferred(\"my_property\", 5).")
		return
		
	if not is_instance_valid(_state):
		push_error("State chart has no root state. Ignoring call to `set_expression_property`.")
		return
	
	_expression_properties[name] = value
	_property_change_pending = true
	_run_changes()
		
		
func _run_changes() -> void:
	if _locked_down:
		return
		
	# enable the reentrance lock
	_locked_down = true
	
	while (not _queued_events.is_empty()) or _property_change_pending:
		# first run any pending property changes, so that we keep the order
		# in which stuff is processed
		if _property_change_pending:
			_property_change_pending = false
			_state._process_transitions(&"", true)
	
		if not _queued_events.is_empty():
			# process the next event	
			var next_event = _queued_events.pop_front()
			event_received.emit(next_event)
			_state._process_transitions(next_event, false)
	
	_locked_down = false


## Allows states to queue a transition for running. This will eventually run the transition
## once all currently running transitions have finished. States should call this method
## when they want to transition away from themselves. 
func _run_transition(transition:Transition, source:State) -> void:
	# if we are currently inside of a transition, queue it up. This can happen
	# if a state has an automatic transition on enter, in which case we want to
	# finish the current transition before starting a new one.
	if _transitions_processing_active:
		_queued_transitions.append({transition : source})
		return
		
	_transitions_processing_active = true

	# we can only transition away from a currently active state
	# if for some reason the state no longer is active, ignore the transition	
	_do_run_transition(transition, source)
	
	# if we still have transitions
	while _queued_transitions.size() > 0:
		var next_transition_entry = _queued_transitions.pop_front()
		var next_transition = next_transition_entry.keys()[0]
		var next_transition_source = next_transition_entry[next_transition]
		_do_run_transition(next_transition, next_transition_source)

	_transitions_processing_active = false

## Runs the transition. Used internally by the state chart, do not call this directly.	
func _do_run_transition(transition:Transition, source:State):
	if not source.active:
		_warn_not_active(transition, source)
		return

	var target = transition.resolve_target()
	if not target is State:
		push_error("The target state '" + str(transition.to) + "' of the transition from '" + source.name + "' is not a state.")
		return
	transition.taken.emit()

	var transition_path:NodePath = source.get_path_to(target)

	# if transition.to is the source state, just let the state exit and re-enter itself
	if transition_path == ^".":
		source._state_exit()
		source._state_enter()
		return

	# otherwise, we go from source to target along the node path
	var parent_state := source
	var child_state:State
	for idx in transition_path.get_name_count():

		# firstly, find the common ancestor of the source and target if these is a common ancestor
		if transition_path.get_name(idx) == &"..":
			parent_state = parent_state.get_parent()
			continue

		# from the ancestor node, we go through the node path to reach the target
		child_state = parent_state.get_node(transition_path.get_name(idx) as String)

		# here we can just focus on compound state, as other types need no extra actions
		if parent_state is CompoundState:
			# no matter what, the child should be the active state of the parent compound state
			# if not, current _active_state should exit
			if parent_state._active_state != null and parent_state._active_state != child_state:
				parent_state._active_state._state_exit()

			# if target state is history state, we first try to restore its saved state if it exists
			if child_state is HistoryState:
				if child_state.history != null:
					parent_state._state_restore(child_state.history, -1 if child_state.deep else 1)
					return

				# otherwise, try enter the default state if it exists
				var default_state = child_state.get_node_or_null(child_state.default_state)
				if is_instance_valid(default_state):
					parent_state.active_state = default_state
					parent_state.active_state._state_enter()
				else:
					push_error("The default state '" + child_state.default_state + "' of the history state '" + child_state.name + "' cannot be found.")
				return

			else:
				parent_state._active_state = child_state
				# we do not expect transition if we do not reach the target yet
				parent_state._active_state._state_enter(child_state != target)

		parent_state = child_state


func _warn_not_active(transition:Transition, source:State):
	push_warning("Ignoring request for transitioning from ", source.name, " to ", transition.to, " as the source state is no longer active. Check whether your trigger multiple state changes within a single frame.")



## Calls the `step` function in all active states. Used for situations where `state_processing` and 
## `state_physics_processing` don't make sense (e.g. turn-based games, or games with a fixed timestep).
func step() -> void:
	if not is_node_ready():
		push_error("State chart is not yet ready. If you call `step` in `_ready`, please call it deferred, e.g. `state_chart.step.call_deferred()`.")
		return
		
	if not is_instance_valid(_state):
		push_error("State chart has no root state. Ignoring call to `step`.")
		return
	_state._state_step()

func _get_configuration_warnings() -> PackedStringArray:
	var warnings:PackedStringArray = []
	if get_child_count() != 1:
		warnings.append("StateChart must have exactly one child")
	else:
		var child:Node = get_child(0)
		if not child is State:
			warnings.append("StateChart's child must be a State")
	return warnings


