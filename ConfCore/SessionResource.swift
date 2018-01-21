//
//  SessionResource.swift
//  ConfCore
//
//  Created by Ben Newcombe on 09/01/2018.
//  Copyright © 2018 Guilherme Rambo. All rights reserved.
//

import Cocoa
import RealmSwift

public enum SessionResourceType: String {
    case none
    case resource = "WWDCSessionResourceTypeResource"
    case activity = "WWDCSessionResourceTypeActivity"
}

public class SessionResource: Object {

    public var identifier: String = ""
    public var type: SessionResourceType = .none

    public override class func primaryKey() -> String? {
        return "identifier"
    }

    
}
