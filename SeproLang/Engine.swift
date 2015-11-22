//
//  Engine.swift
//  AgentFarms
//
//  Created by Stefan Urbanek on 02/10/15.
//  Copyright © 2015 Stefan Urbanek. All rights reserved.
//


// Note: The code might be over-modularized and there might be too many
// classes, but that is intentional during the early development phase as it
// helps in the thinking process. Concepts might be merged later in the
// process of conceptual optimizaiion.


public protocol Store {
    /** Initialize the store with `world`. If `world` is not specified then
    `main` is used.
    */
    func initialize(world: Symbol) throws

    /** Instantiate concept `name`.
     - Returns: reference to the newly created object
     */
    func instantiate(name: Symbol) throws -> ObjectRef

    /**
     Iterator through all objects.
     
     - Note: Order is implementation specific and is not guaranteed
       neigher between implementations or even between distinct calls
       of the method even without state change of the store.
     - Returns: sequence of all object references
    */
    var objects: ObjectSelection { get }

    /**
    - Returns: sequence of all object references
    */
    func getObject(ref: ObjectRef) -> Object?

    /**
    - Returns: root object
     */
    func getRoot() -> Object

    /**
     Iterates through all objects mathing `predicates`. Similar to
     `objects` the order in which the objects are iterated over is
     engine specific.
     */
    func select(predicates:[Predicate]) -> Selection
    func evaluate(predicate:Predicate, _ ref:ObjectRef) -> Bool

    var model:Model { get }
}

/**
    Simulation engine interface
*/
public protocol Engine {

    /**
     Run simulation for `steps` number of steps.

     If a trap occurs during the execution the delegate will be notified
     and the simulation run will be stopped.
     
     If `HALT` action was encountered, the simulation is terminated and
     can not be resumed unless re-initialized.
     */
    func run(steps:Int)
    var stepCount:Int { get }

    var store:SimpleStore { get }
}

// MARK: Selection Generator

// TODO: make this a protocol, since we can't expose our internal
// implementation of object

/**
Container representing the state of the world.
*/
public class SimpleStore: Store {
    // TODO: Merge this with engine, make distinction between public methods
    // with IDs and private methods with direct object references

    public var model: Model
    public var stepCount: Int

    /// The object memory
    public var objectMap: [ObjectRef:Object]
    public var objectCounter: Int = 1

    /// Reference to the root object in the object memory
    public var root: ObjectRef!

    public init(model:Model) {
        self.model = model
        self.objectMap = [ObjectRef:Object]()
        self.root = nil
        self.stepCount = 0

    }

    public var objects: ObjectSelection {
        get { return AnySequence(self.objectMap.values) }
    }

    public func getObject(ref:ObjectRef) -> Object? {
        return self.objectMap[ref]
    }

    /**
        Initialize the store according to the model. All existing objects will
    be discarded.
    */
    public func initialize(worldName: Symbol="main") throws {
        // FIXME: handle non-existing world
        let world = self.model.getWorld(worldName)!

        // Clean-up the objects container
        self.objectMap.removeAll()
        self.objectCounter = 1

        if let rootConcept = world.root {
            self.root = try self.instantiate(rootConcept)
        }
        else {
            self.root = self.create()
        }

        try self.instantiateStructContents(world.contents)
    }
    /**
     Creates instances of objects in the GraphDescription and returns a
     dictionary of created named objects.
     */
    func instantiateStructContents(contents: StructContents) throws -> ObjectMap {
        var map = ObjectMap()

        try contents.contentObjects.forEach() { obj in
            switch obj {
            case let .Named(concept, name):
                map[name] = try self.instantiate(concept)
            case let .Many(concept, count):
                for _ in 1...count {
                    try self.instantiate(concept)
                }
            }
        }

        return map
    }

    public func instantiate(name:Symbol) throws -> ObjectRef {
        let concept = self.model.getConcept(name)
        return self.create(concept!)
    }

    /**
     Create an object instance from `concept`. If concept is not provided,
     then creates an empty object.
     
     - Returns: reference to the newly created object
    */
    public func create(concept: Concept!=nil) -> ObjectRef {
        let ref = self.objectCounter
        let obj = Object(ref)

        if concept != nil {
            obj.tags = concept.tags
            obj.counters = concept.counters
            for slot in concept.slots {
                obj.links[slot] = nil
            }

            // Concept name is one of the tags
            obj.tags.insert(concept.name)
        }

        self.objectMap[ref] = obj
        self.objectCounter += 1

        return ref
    }

    public subscript(ref: ObjectRef) -> Object? {
        return self.objectMap[ref]
    }

    /**
    - Returns: instance of the root object.
    */
    public func getRoot() -> Object {
        // Note: this must be fullfilled
        return self[self.root]!
    }

    /**
        Create a structure of conceptual objects
    */
    public func createStruct(str:Struct) throws {
        // var instances = [String:Object]()

        // Create concept instances
//        for (name, concept) in str.concepts {
//            let obj = self.createObject(concept)
//            instances[name] = obj
//        }
//
//
//        for (sourceRef, targetRef) in str.links {
//
//            guard let source = instances[sourceRef.owner] else {
//                throw SimulationError.UnknownObject(name:sourceRef.owner)
//            }
//            guard let target = instances[targetRef] else  {
//                throw SimulationError.UnknownObject(name:targetRef)
//            }
//
//
//            source.links[sourceRef.property] = target
//        }
    }



    /**
        Matches objects of the simulation against `conditions`.
    
        - Returns: Generator of matching objects.
        - Note: If selection matches an object first, then object
          changes state so that it does not match the predicate,
          the object will not be included in the result.
    */


    public func select(predicates:[Predicate]) -> Selection {
        return Selection(store: self, predicates: predicates)
    }

    /**
        Evaluates the predicate against object.
        - Returns: `true` if the object matches the predicate
    */
    public func evaluate(predicate:Predicate,_ ref: ObjectRef) -> Bool {
        if let object = self.objectMap[ref] {
            var target: Object

            // Try to get the target slot
            //
            if predicate.inSlot != nil {
                if let maybeTarget = object.links[predicate.inSlot!] {
                    target = self.objectMap[maybeTarget]!
                }
                else {
                    // TODO: is this OK if the slot is not filled and the condition is
                    // negated?
                    return false
                }
            }
            else {
                target = object
            }
            return predicate.evaluate(target)
        }
        else {
            // TODO: Exception?
            return false
        }
    }
}

public protocol EngineDelegate {
    func willRun(engine: Engine)
    func didRun(engine: Engine)
    func willStep(engine: Engine, objects:ObjectSelection)
    func didStep(engine: Engine)

    func handleTrap(engine: Engine, traps: CountedSet<Symbol>)
    func handleHalt(engine: Engine)
}

/**
    SimpleEngine – simple implementation of computational engine. Performs
    computations of simulation steps, captures traps and observes probe values.
*/

public class SimpleEngine: Engine {
    /// Current step
    public var stepCount = 0

    /// Simulation state instance
    public var store: SimpleStore

    /// Traps caught in the last step
    public var traps = CountedSet<Symbol>()

    /// Flag saying whether the simulation is halted or not.
    public var isHalted: Bool

    // Probing
    // -------

    /// List of probes
    public var probes: [Probe]

    /// Logging delegate – an object that implements the `Logger`
    /// protocol
    public var logger: Logger?

    /// Delegate for handling traps, halt and other events
    public var delegate: EngineDelegate?


    /// Simulation model
    public var model: Model {
        return self.store.model
    }

    /**
        Create an object instance from concept
    */
    public init(_ store:SimpleStore){
        self.store = store
        self.isHalted = false
        self.logger = nil
        self.probes = [Probe]()
        self.delegate = nil
    }

    convenience public init(model:Model){
        let store = SimpleStore(model: model)
        self.init(store)
    }

    /**
        Runs the simulation for `steps`.
    */
    public func run(steps:Int) {
        if self.logger != nil {
            self.logger!.loggingWillStart(self.model.measures, steps: steps)
            // TODO: this should be called only on first run
            self.probe()
        }
        
        // self.delegate?.willRun(self)
        var stepsRun = 0

        for _ in 1...steps {

            self.step()

            if self.isHalted {
                self.delegate?.handleHalt(self)
                break
            }

            stepsRun += 1
        }

        self.logger?.loggingDidEnd(stepsRun)
    }

    /**
        Compute one step of the simulation by evaluating all actuators.
    */
    func step() {
        self.traps.removeAll()

        stepCount += 1

        self.delegate?.willStep(self, objects: self.store.objects)

        // The main step...
        // --> Start of step
        self.model.actuators.forEach(self.perform)

        // <-- End of step

        self.delegate?.didStep(self)

        if self.logger != nil {
            self.probe()
        }

        if !self.traps.isEmpty {
            self.delegate?.handleTrap(self, traps: self.traps)
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
            (measure, createProbe(measure))
        }

        // TODO: too complex
        self.store.objects.forEach {
            object in
            probeList.forEach {
                measure, probe in
                if measure.predicates.all({ self.store.evaluate($0, object.id) }) {
                    probe.probe(object)
                }
            }
        }

        // Gather the probe results
        // TODO: replace this with Array<tuple> -> Dictionary
        probeList.forEach {
            measure, probe in
            record[measure.name] = probe.value
        }

        self.logger!.logRecord(self.stepCount, record: record)
    }

    /**
        Dispatch an `actuator` – reactive vs. interactive.
     */
    func perform(actuator:Actuator){
        // TODO: take into account Actuator.isRoot as cartesian
        if actuator.selector.otherPredicates != nil {
            self.performCartesian(actuator)
        }
        else
        {
            self.performSingle(actuator)
        }

        // FIXME: this is lame, make sure the types are compatible
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
                self.notify(notification)
            }
        }

        self.isHalted = actuator.doesHalt
    }

    /**
    Interactive actuator execution.

    Algorithm:

    1. Find objects matching conditions for `this`
    2. Find objects matching conditions for `other`
    3. If any of the sets is empty, don't perform anything – there is
       no reaction
    4. Perform reactive action on the objects.

    - Complexity: O(n) - performs full scan
    */
    func performSingle(actuator:Actuator) {
        let thisObjects = self.store.select(actuator.selector.predicates)

        var counter = 0
        for this in thisObjects {
            counter += 1
            actuator.modifiers.forEach {
                modifier in
                self.applyModifier(modifier, this: this)
            }
        }

    }

    /**
    - Complexity: O(n^2) - performs cartesian product on two full scans
    */

    func performCartesian(actuator:Actuator) {
        let thisObjects = self.store.select(actuator.selector.predicates)
        let otherObjects = self.store.select(actuator.selector.otherPredicates!)

        // Cartesian product: everything 'this' interacts with everything
        // 'other'
        for this in thisObjects {
            for other in otherObjects{
                actuator.modifiers.forEach {
                    modifier in
                    self.applyModifier(modifier, this: this, other: other)
                }

                // Check whether 'this' still matches the predicates
                let match = actuator.selector.predicates.all {
                    predicate in
                    self.store.evaluate(predicate, this.id)
                }

                // ... predicates don't match the object, therefore we
                // skip to the next one
                if !match {
                    break
                }
            }
        }

    }

    /**
        Get "current" object – choose between ROOT, THIS and OTHER then
    optionally apply dereference to a slot, if specified.
    */
    func getCurrent(ref: CurrentRef, this: Object, other: Object!) -> Object! {
            let current: Object!

            switch ref.type {
            case .Root:
                current = self.store.getRoot()
            case .This:
                current = this
            case .Other:
                current = other
            }

            if current == nil {
                return nil
            }

            if ref.slot != nil {
                return self.store.getObject(current.links[ref.slot!]!)
            }
            else {
                return current
            }
    }

    /**
    Execute instruction
    */

    func applyModifier(modifier:Modifier, this:Object, other:Object!=nil) {
        // Note: Similar to the Predicate code, we are not using language
        // polymorphysm here. This is not proper way of doing it, but
        // untill the action objects are refined and their executable
        // counterparts defined, this should remain as it is.

        let current = self.getCurrent(modifier.currentRef, this: this, other: other)
        print("MODIFY \(modifier.action) IN \(modifier.currentRef)(\(current.id)) \(this)<->\(other)")

        switch modifier.action {
        case .Nothing:
            // Do nothing
            break

        case .SetTags(let tags):
            current.tags = current.tags.union(tags)

        case .UnsetTags(let tags):
            current.tags = current.tags.subtract(tags)

        case .Inc(let counter):
            let value = current.counters[counter]!
            current.counters[counter] = value + 1

        case .Dec(let counter):
            let value = current.counters[counter]!
            current.counters[counter] = value + 1

        case .Clear(let counter):
            current.counters[counter] = 0

        case .Bind(let targetRef, let slot):
            let target = self.getCurrent(targetRef, this: this, other: other)
            print("   TARGET \(target) (\(targetRef))")
            if current != nil && target != nil {
                current.links[slot] = target.id
            }
            else {
                // TODO: isn't this an error or invalid state?
            }

        case .Unbind(let slot):
            if current != nil {
                this.links[slot] = nil
            }
            else {
                // TODO: isn't this an error or invalid state?
            }
        }
    }

    func notify(symbol: Symbol) {
        self.logger?.logNotification(self.stepCount, notification: symbol)
    }

    public func debugDump() {
        print("ENGINE DUMP START\n")
        print("STEP \(self.stepCount)")
        self.store.objects.forEach {
            obj in
            print("\(obj.debugString)")
        }
        print("END OF DUMP\n")
    }
}
