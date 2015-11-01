//
//  main.swift
//  sepro
//
//  Created by Stefan Urbanek on 29/10/15.
//  Copyright © 2015 Stefan Urbanek. All rights reserved.
//

import Foundation
import SeproLang

let processInfo = NSProcessInfo.processInfo()

func usage() {
    print("Usage: \(processInfo.processName) MODEL STEPS")
}

func main() {
    let engine: SimpleEngine
    let args = processInfo.arguments
    let source: String
    let modelFile: String
    let stepCount: Int

    if args.count < 2 {
        usage()
        return
    }

    modelFile = args[1]
    stepCount = Int(args[2])!

    print("Loading model from \(modelFile)...")

    do {
        source = try String(contentsOfFile: modelFile, encoding:NSUTF8StringEncoding)
    } catch {
        print("Error: Unable to read model.")
        return
    }

    print("Compiling model...")
    let parser = Parser(source: source)
    if let model:Model = parser.compile() {
        print("Model compiled: \(model.concepts.count) concepts. \(model.actuators.count) actuators")
        engine = SimpleEngine(model:model)
    }
    else {
        print("Error compiling model: \(parser.currentLine): \(parser.error!)")
        return
    }


    do {
        try engine.store.initialize()
    }
    catch {
        print("Error: Can't initialize engine")
        return
    }

    engine.debugDump()
    engine.run(stepCount)
    engine.debugDump()

}

main()

print("HELLO")