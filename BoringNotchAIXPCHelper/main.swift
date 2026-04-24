import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Set up exported interface (XPC Helper's service)
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchAIXPCHelperProtocol).self)

        // Set up remote object interface (main app's listener)
        // This enables XPC Helper to call back to the main app
        newConnection.remoteObjectInterface = NSXPCInterface(with: AIXPCEventListener.self)

        let exportedObject = BoringNotchAIXPCHelper()

        // Store connection reference so helper can access remoteObjectProxy
        exportedObject.setConnection(newConnection)

        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
