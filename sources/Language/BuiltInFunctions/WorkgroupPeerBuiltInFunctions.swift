//
//  WorkgroupPeerBuiltInFunctions.swift
//  iTerm2SharedARC
//

import Foundation

// iterm2.add_workgroup_peer and iterm2.remove_workgroup_peer: add a member to
// the workgroup of the calling session, or remove one added that way. They
// let an agent in a workgroup run helpers as segments of its peer switcher
// rather than in tabs of their own.
private enum WorkgroupPeerBuiltInFunctionSupport {
    static let errorDomain = "com.iterm2.workgroup-peer"
    static let argSession = "session"

    static func error(_ message: String) -> NSError {
        return NSError(domain: errorDomain,
                       code: 1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func instance(for session: PTYSession,
                         completion: iTermBuiltInFunctionCompletionBlock) -> iTermWorkgroupInstance? {
        guard let instance = session.workgroupInstance else {
            completion(nil, error(String(localized: "WorkgroupPeer.NotInWorkgroup",
                                         defaultValue: "This session isn’t in a workgroup.",
                                         comment: "Error when adding or removing a workgroup peer from a session that isn’t in a workgroup")))
            return nil
        }
        return instance
    }
}

@objc(iTermAddWorkgroupPeerBuiltInFunction)
class AddWorkgroupPeerBuiltInFunction: NSObject {
    private static let argName = "name"
    private static let argCommand = "command"
    private static let argActivate = "activate"
}

extension AddWorkgroupPeerBuiltInFunction: iTermBuiltInFunctionProtocol {
    static func register() {
        typealias S = WorkgroupPeerBuiltInFunctionSupport
        let builtInFunction = iTermBuiltInFunction(
            name: "add_workgroup_peer",
            arguments: [argName: NSString.self,
                        argCommand: NSString.self,
                        argActivate: NSNumber.self],
            optionalArguments: Set([argCommand, argActivate]),
            defaultValues: [S.argSession: iTermVariableKeySessionID],
            context: .session,
            // Localization unneeded
            sideEffectsPlaceholder: "[add_workgroup_peer]") { parameters, completion in
                guard let session = iTermBuiltInFunction.session(for: parameters,
                                                                 key: S.argSession,
                                                                 errorDomain: S.errorDomain,
                                                                 completion: completion),
                      let instance = S.instance(for: session, completion: completion) else {
                    return
                }
                guard let name = parameters[argName] as? String else {
                    completion(nil, S.error(String(localized: "WorkgroupPeer.MissingName",
                                                   defaultValue: "Missing required argument “name”",
                                                   comment: "Error when add_workgroup_peer is called without a name")))
                    return
                }
                let command = parameters[argCommand] as? String ?? ""
                let activate = (parameters[argActivate] as? NSNumber)?.boolValue ?? false
                let added: (identifier: String, promise: iTermPromise<PTYSession>)
                do {
                    added = try instance.addDynamicPeer(name: name, command: command)
                } catch {
                    completion(nil, S.error(error.localizedDescription))
                    return
                }
                added.promise.then { [weak instance] peer in
                    if activate {
                        _ = instance?.peerPort.activate(identifier: added.identifier)
                    }
                    completion(peer.guid, nil)
                }.catchError { error in
                    completion(nil, S.error(error.localizedDescription))
                }
            }
        iTermBuiltInFunctions.sharedInstance().register(builtInFunction, namespace: "iterm2")
    }
}

@objc(iTermRemoveWorkgroupPeerBuiltInFunction)
class RemoveWorkgroupPeerBuiltInFunction: NSObject {
    private static let argPeer = "peer"
}

extension RemoveWorkgroupPeerBuiltInFunction: iTermBuiltInFunctionProtocol {
    static func register() {
        typealias S = WorkgroupPeerBuiltInFunctionSupport
        let builtInFunction = iTermBuiltInFunction(
            name: "remove_workgroup_peer",
            arguments: [argPeer: NSString.self],
            optionalArguments: Set(),
            defaultValues: [S.argSession: iTermVariableKeySessionID],
            context: .session,
            // Localization unneeded
            sideEffectsPlaceholder: "[remove_workgroup_peer]") { parameters, completion in
                guard let session = iTermBuiltInFunction.session(for: parameters,
                                                                 key: S.argSession,
                                                                 errorDomain: S.errorDomain,
                                                                 completion: completion),
                      let instance = S.instance(for: session, completion: completion) else {
                    return
                }
                guard let guid = parameters[argPeer] as? String,
                      let peer = instance.peerPort.peerSession(withGUID: guid),
                      let identifier = instance.peerPort.identifier(for: peer),
                      instance.removeDynamicPeer(identifier: identifier) else {
                    completion(nil, S.error(String(localized: "WorkgroupPeer.CantRemove",
                                                   defaultValue: "That session isn’t a peer added to this workgroup, or it can’t be removed now.",
                                                   comment: "Error when remove_workgroup_peer can’t remove the given session")))
                    return
                }
                completion(nil, nil)
            }
        iTermBuiltInFunctions.sharedInstance().register(builtInFunction, namespace: "iterm2")
    }
}
