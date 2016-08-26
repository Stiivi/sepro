//
//	Engine.swift
//	AgentFarms
//
//	Created by Stefan Urbanek on 02/10/15.
//	Copyright © 2015 Stefan Urbanek. All rights reserved.
//

import Model

/**
	Simulation engine interface
*/
public protocol Engine {

	var model:Model { get }
	var container:Container { get }


	/// Run simulation for `steps` number of steps.
	/// 
	/// If a trap occurs during the execution the delegate will be notified
	/// and the simulation run will be stopped.
	/// 
	/// If `HALT` action was encountered, the simulation is terminated and
	/// can not be resumed unless re-initialized.
	func run(steps:Int)
	var stepCount:Int { get }

	/// Initialize the container with `world`. If `world` is not specified then
	/// `main` is used.
	func initialize(worldName: Symbol) throws

	/// Instantiate concept `name`.
	/// - Returns: reference to the newly created object
	// TODO: move to engine, change this to add(object)
	func instantiate(name: Symbol, initializers:[Initializer]) throws -> ObjectRef

}

// MARK: Selection Generator

// TODO: make this a protocol, since we can't expose our internal
// implementation of object

public protocol EngineDelegate {
	func willRun(engine: Engine)
	func didRun(engine: Engine)
	func willStep(engine: Engine)
	func didStep(engine: Engine)

	func handleTrap(engine: Engine, traps: CountedSet<Symbol>)
	func handleHalt(engine: Engine)
}

/**
	SimpleEngine – simple implementation of computational engine. Performs
	computations of simulation steps, captures traps and observes probe values.
*/

public final class SimpleEngine: Engine {
	/// Simulation model
	public let model: Model

	/// Simulation state instance
	public var container: Container

	/// Current step
	public var stepCount = 0

	/// Traps caught in the last step
	public var traps = CountedSet<Symbol>()

	/// Flag saying whether the simulation is halted or not.
	public var isHalted: Bool = false

	// Probing
	// -------

	/// List of probes
	public var probes: [Probe]

	/// Logging delegate – an object that implements the `Logger`
	/// protocol
	public var logger: Logger? = nil

	/// Delegate for handling traps, halt and other events
	public var delegate: EngineDelegate? = nil


	/// Create an object instance from concept
	public init(model:Model, container: Container?=nil){
		self.container = container ?? Container()
		self.model = model

		self.probes = [Probe]()
	}

	/// Runs the simulation for `steps`.
	public func run(steps:Int) {
		if self.logger != nil {
			self.logger!.loggingWillStart(measures: self.model.measures, steps: steps)
			// TODO: this should be called only on first run
			self.probe()
		}
		
		self.delegate?.willRun(engine:self)
		var stepsRun = 0

		for _ in 1...steps {

			self.step()

			if self.isHalted {
				self.delegate?.handleHalt(engine:self)
				break
			}

			stepsRun += 1
		}

		self.logger?.loggingDidEnd(steps: stepsRun)
	}

	/**
		Compute one step of the simulation by evaluating all actuators.
	*/
	func step() {
		self.traps.removeAll()

		stepCount += 1

		self.delegate?.willStep(engine: self)

		// >>>
		// The main step...
		self.model.actuators.shuffle().forEach(self.perform)
		// <<<

		self.delegate?.didStep(engine: self)

		if self.logger != nil {
			self.probe()
		}

		if !self.traps.isEmpty {
			self.delegate?.handleTrap(engine: self, traps: self.traps)
		}
	}

	/**
	 Probe the simulation and pass the results to the logger. Probing
	 is ignored when logger is not provided.

	 - Complexity: O(n) – does full scan on all objects
	 */
	func probe() {
		var record = ProbeRecord()

		// Nothing to probe if we have no logger
		if self.logger == nil {
			return
		}

		// Create the probes
		let probeList = self.model.measures.map {
			measure in
			(measure, createProbe(measure: measure))
		}

		// TODO: too complex
		self.container.select().forEach {
			object in
			probeList.forEach {
				measure, probe in
				if self.container.predicatesMatch(predicates: measure.predicates, ref: object.id) {
					probe.probe(object: object)
				}
			}
		}

		// Gather the probe results
		// TODO: replace this with Array<tuple> -> Dictionary
		probeList.forEach {
			measure, probe in
			record[measure.name] = probe.value
		}

		self.logger!.logRecord(step: self.stepCount, record: record)
	}

	/// Dispatch an `actuator` – unary vs. combined
	///
	func perform(actuator:Actuator){
		if actuator.isCombined {
			self.perform(this: actuator.selector,
						 other: actuator.combinedSelector!,
						 actuator: actuator)
		}
		else {
			self.perform(unary: actuator.selector, actuator: actuator)
		}

		// Handle traps
		//
		if actuator.traps != nil {
			actuator.traps!.forEach {
				trap in
				self.traps.add(trap)
			}
		}

		// TODO: handle 'ONCE'
		// TODO: maybe handle similar way as traps
		if actuator.notifications != nil {
			actuator.notifications!.forEach {
				notification in
				self.notify(symbol:notification)
			}
		}

		self.isHalted = actuator.doesHalt
	}


	/// Unary actuator execution.
	///
	/// - Complexity: O(n) - performs full scan
	///
	// TODO: rename to perform(unary:)
	func perform(unary selector: Selector, actuator: Actuator) {
		let objects = self.container.select(selector)

		for this in objects {
			// Check for required slots
			if !actuator.modifiers.all({ self.canApply(modifier: $0, this: this) }) {
				continue
			}

			actuator.modifiers.forEach {
				modifier in
				self.apply(modifier: modifier, this: this)
			}
		}

	}

	/// Combined actuator execution.
	///
	/// Algorithm:
	///
	/// 1. Find objects matching conditions for `this`
	/// 2. Find objects matching conditions for `other`
	/// 3. If any of the sets is empty, don't perform anything – there is
	///    no reaction
	/// 4. Perform reactive action on the objects.
	///
	/// - Complexity: O(n^2) - performs cartesian product on two full scans
	///
	func perform(this thisSelector: Selector, other otherSelector: Selector,
		actuator: Actuator) {

		let thisObjects = self.container.select(thisSelector)
		let otherObjects = self.container.select(otherSelector)

		var match: Bool

		// Cartesian product: everything 'this' interacts with everything
		// 'other'
		// Note: We can't use forEach, as there is no way to break from the loop
		for this in thisObjects {
			// Check for required slots
			for other in otherObjects {
				// Check for required slots
				if !actuator.modifiers.all({ self.canApply(modifier: $0, this: this, other: other) }) {
					continue
				}
				if this.id == other.id {
					continue
				}

				actuator.modifiers.forEach {
					modifier in
					self.apply(modifier: modifier, this: this, other: other)
				}

				// Check whether 'this' still matches the predicates
				match = thisSelector == Selector.All ||
						container.predicatesMatch(predicates: thisSelector.predicates, ref: this.id)
				// ... predicates don't match the object, therefore we
				// skip to the next one
				if !match {
					break
				}
			}
		}

	}

	/// Get "current" object – choose between ROOT, THIS and OTHER then
	/// optionally apply dereference to a slot, if specified.
	///
	func getCurrent(_ ref: ModifierTarget, this: Object, other: Object?=nil) -> Object? {
		let current: Object

		switch ref.type {
		case .Root:
			// Is guaranteed to exist by specification
			current = self.container.getObject(self.container.root)!
		case .This:
			// Is guaranteed to exist by argument
			current = this
		case .Other:
			// Exists only in combined selectors
			assert(other != nil, "Required `other` for .Other target reference")
			current = other!
		}

		if ref.slot == nil {
			return current
		}
		else {
			assert(current.slots.contains(ref.slot!), "Target sohuld contain slot '\(ref.slot!)'")
			if let indirect = current.bindings[ref.slot!] {
				return self.container[indirect]!
			}
			else {
				// Nothing bound at the slot
				return nil
			}

		}
	}

	/// - Returns: `true` if the `modifier` can be applied, otherwise `false`
	func canApply(modifier:Modifier, this:Object, other:Object!=nil) -> Bool {
		let current = self.getCurrent(modifier.target, this: this, other: other)

		switch modifier.action {
		case .Inc(let counter):
			return current?.counters.keys.contains(counter) ?? false

		case .Dec(let counter):
			if let value = current?.counters[counter] {
				return value > 0
			}
			else {
				return false
			}

		case .Clear(let counter):
			return current?.counters.keys.contains(counter) ?? false

		case .Bind(let slot, let targetRef):
			let target = self.getCurrent(targetRef, this: this, other: other)

			if current == nil || target == nil {
				// There is nothing to bind
				// TODO: Should be consider assigning nil as 'unbind' or as failure?
				return false
			}

			return current?.slots.contains(slot) ?? false

		case .Unbind(let slot):
			return current?.slots.contains(slot) ?? false
		default:
			return true
		}
	}

	/// Applies `modifier` on either `this` or `other` depending on the modifier's
	/// target
	// TODO: apply(modifier:to:)
	func apply(modifier:Modifier, this:Object, other:Object?=nil) {
		guard let current = self.getCurrent(modifier.target, this: this, other: other) else {
			preconditionFailure("Current object for modifier should not be nil (apllication should be guarded)")
		}

		switch modifier.action {
		case .Nothing:
			// Do nothing
			break

		case .SetTags(let tags):
			current.tags = current.tags.union(tags)

		case .UnsetTags(let tags):
			current.tags = current.tags.subtracting(tags)

		case .Inc(let counter):
			let value = current.counters[counter]!
			current.counters[counter] = value + 1

		case .Dec(let counter):
			let value = current.counters[counter]!
			current.counters[counter] = value - 1

		case .Clear(let counter):
			current.counters[counter] = 0

		case .Bind(let slot, let targetRef):
			guard let target = self.getCurrent(targetRef, this: this, other: other) else {
				preconditionFailure("Target sohuld not be nil (application should be guarded)")
			}

			current.bindings[slot] = target.id

		case .Unbind(let slot):
			this.bindings[slot] = nil
		}
	}

	func notify(symbol: Symbol) {
		self.logger?.logNotification(step: self.stepCount, notification: symbol)
	}

	// MARK: Instantiation

	/// Initialize the container according to the model. All existing objects will
	/// be discarded.
	public func initialize(worldName: Symbol="main") throws {
		// FIXME: handle non-existing world
		let world = self.model.getWorld(name: worldName)!

		// Clean-up the objects container
		self.container.removeAll()

		if let rootConcept = world.root {
			self.container.root = try self.instantiate(name: rootConcept)
		}
		else {
			self.container.root = self.container.createObject()
		}

		try self.instantiateGraph(graph: world.graph)
	}
	/// Creates instances of objects in the GraphDescription and returns a
	/// dictionary of created named objects.
	@discardableResult
	func instantiateGraph(graph: InstanceGraph) throws -> ObjectMap {
		var map = ObjectMap()

		try graph.instances.forEach() { inst in
			switch inst.type {
			case let .Named(name):
				map[name] = try self.instantiate(name: inst.concept,
												 initializers: inst.initializers)
			case let .Counted(count):
				for _ in 1...count {
					try self.instantiate(name: inst.concept,
										 initializers: inst.initializers)
				}
			}
		}

		return map
	}


	/// Instantiate a concept `concept` with optional initializers for tags
	/// and concepts `initializers`. Created instance will have additional tag
	/// set – the concept name symbol. 
	/// 
	/// - Returns: reference to the newly created object
	@discardableResult
	public func instantiate(name:Symbol, initializers: [Initializer]=[]) throws -> ObjectRef {
		if let concept = self.model.getConcept(name: name) {
			let implicitTags = TagList([name])
			let tags = concept.tags.union(implicitTags)
			var counters = concept.counters

			let initTags = TagList(initializers.flatMap {
   				initializer in
				switch initializer {
				case let .Tag(symbol): return symbol
				default: return nil
				}
			})

			let initCounters:[(Symbol,Int)] = initializers.flatMap {
   				initializer in
				switch initializer {
				case let .Counter(symbol, value): return (symbol, value)
				default: return nil
				}
			}

			counters.update(from: Dictionary(items:initCounters))
		
			let ref = container.createObject(tags: tags.union(initTags),
											 counters:counters,
											 slots:concept.slots)
			return ref
		}
		else {
			throw SeproError.ModelError("Can not instantiate '\(name)': no such concept")
		}
	}

	/// Create a structure of conceptual objects
	public func createStruct(str:Struct) throws {
		// var instances = [String:Object]()

		// Create concept instances
//		  for (name, concept) in str.concepts {
//			  let obj = self.createObject(concept)
//			  instances[name] = obj
//		  }
//
//
//		  for (sourceRef, targetRef) in str.links {
//
//			  guard let source = instances[sourceRef.owner] else {
//				  throw SimulationError.UnknownObject(name:sourceRef.owner)
//			  }
//			  guard let target = instances[targetRef] else	{
//				  throw SimulationError.UnknownObject(name:targetRef)
//			  }
//
//
//			  source.links[sourceRef.property] = target
//		  }
	}

	public func debugDump() {
		print("ENGINE DUMP START\n")
		print("STEP \(self.stepCount)")
		self.container.select().forEach {
			obj in
			print("\(obj.debugDescription)")
		}
		print("END OF DUMP\n")
	}
}

extension Predicate {
    /**
     Evaluate predicate on `object`.
     
     - Returns: `true` if `object` matches predicate, otherwise `false`
     */
    public func matchesObject(object: Object) -> Bool {
        let result: Bool

        switch self.type {
        case .All:
            result = true

        case .TagSet(let tags):
            if isNegated {
                result = tags.isDisjoint(with:object.tags)
            }
            else {
                result = tags.isSubset(of:object.tags)
            }

        case .CounterZero(let counter):
            if let counterValue = object.counters[counter] {
                result = (counterValue == 0) != self.isNegated
            }
            else {
                // TODO: Shouldn't we return false or have invalid state?
                result = false
            }

        case .IsBound(let slot):
            result = (object.bindings[slot] != nil) != self.isNegated
        }

        return result
    }
}