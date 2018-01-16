import Async
import Foundation
import Bits
import HTTP
import Crypto
import TCP

/// A websocket connection. Can be either the client or server side of the connection
///
/// [Learn More →](https://docs.vapor.codes/3.0/websocket/websocket/)
public final class WebSocket {
    // Gets called on WebSocket close
    public typealias OnClose = (WebSocket, ByteBuffer) throws -> ()
    
    // Gets called on WebSocket error
    public typealias OnError = (WebSocket, Error) -> ()
    
    // Gets called on WebSocket text
    public typealias OnText = (WebSocket, String) throws -> ()
    
    // Gets called on WebSocket binary
    public typealias OnBinary = (WebSocket, ByteBuffer) throws -> ()
    
    /// A stream of strings received from the remote
    public let textStream: EmitterStream<String>
    
    /// A stream of binary data received from the remote
    public let binaryStream: EmitterStream<ByteBuffer>
    
    /// Allows push stream access to the frame serializer
    let serializerStream: PushStream<Frame>
    
    // Gets called on WebSocket close
    var closeListener: OnClose = { _, _ in }
    
    // Gets called on WebSocket error
    var errorListener: OnError = { _, _ in }
    
    // Gets called on WebSocket text data
    var textListener: OnText = { _, _ in }
    
    // Gets called on WebSocket binary data
    var binaryListener: OnBinary = { _, _ in }
    
    /// Serializes frames into data
    let serializer: FrameSerializer
    
    /// Parses frames from data
    let parser: TranslatingStreamWrapper<FrameParser>
    
    let server: Bool
    
    var worker: Worker
    
    var httpSerializerStream: PushStream<HTTPRequest>?
    
    /// Keeps track of sent pings that await a response
    var pings = [Data: Promise<Void>]()
    
    /// The underlying communication layer
    let source: AnyOutputStream<ByteBuffer>
    let sink: AnyInputStream<ByteBuffer>
    
    /// Create a new WebSocket from a TCP client for either the Client or Server Side
    ///
    /// Server side connections do not mask sent data
    ///
    /// - parameter client: The TCP.Client that the WebSocket connection runs on
    /// - parameter serverSide: If `true`, run the WebSocket as a server side connection.
    init(
        source: AnyOutputStream<ByteBuffer>,
        sink: AnyInputStream<ByteBuffer>,
        worker: Worker,
        server: Bool = true
    ) {
        self.parser = FrameParser(worker: worker).stream(on: worker)
        self.serializer = FrameSerializer(masking: !server)
        self.source = source
        self.sink = sink
        self.worker = worker
        self.server = server
        
        self.textStream = EmitterStream<String>()
        self.binaryStream = EmitterStream<ByteBuffer>()
        
        self.serializerStream = PushStream<Frame>()
    }
    
    /// Upgrades the connection over HTTP
    func upgrade(uri: URI) {
        // Generates the UUID that will make up the WebSocket-Key
        let id = OSRandom().data(count: 16).base64EncodedString()
        
        // Creates an HTTP client for the handshake
        let serializer = HTTPRequestSerializer().stream(on: self.worker)
        let serializerStream = PushStream<HTTPRequest>()
        
        let responseParser = HTTPResponseParser()
        responseParser.maxHeaderSize = 50_000
        
        let parser = responseParser.stream(on: self.worker)
        
        serializerStream.stream(to: serializer).output(to: self.sink)
        
        let drain = DrainStream<HTTPResponse>(onInput: { response, upstream in
            try WebSocket.upgrade(response: response, id: id)
            
            self.bindFrameStreams()
        })
        
        self.source.stream(to: parser).output(to: drain)
        
        parser.request()
        
        let request = HTTPRequest(method: .get, uri: uri, headers: [
            .connection: "Upgrade",
            .upgrade: "websocket",
            .secWebSocketKey: id,
            .secWebSocketVersion: "13"
        ], body: HTTPBody())
        
        self.httpSerializerStream = serializerStream
        serializerStream.next(request)
    }
    
    func bindFrameStreams() {
         _ = source.stream(to: parser).drain { frame, upstream in
            defer {
                self.parser.request()
            }
            
            frame.unmask()
            
            switch frame.opCode {
            case .close:
                try self.closeListener(self, frame.payload)
                self.parser.close()
                self.textStream.close()
                self.binaryStream.close()
            case .text:
                let data = Data(buffer: frame.payload)
                
                guard let string = String(data: data, encoding: .utf8) else {
                    throw WebSocketError(.invalidFrame)
                }
                
                try self.textListener(self, string)
                self.textStream.emit(string)
            case .continuation, .binary:
                try self.binaryListener(self, frame.payload)
                self.binaryStream.emit(frame.payload)
            case .ping:
                let frame = Frame(op: .pong, payload: frame.payload, mask: self.nextMask)
                self.serializerStream.next(frame)
            case .pong:
                let data = Data(frame.payload)
                self.pings[data]?.complete()
            }
        }.catch { error in
            self.errorListener(self, error)
        }.finally {
            self.serializerStream.close()
            self.textStream.close()
            self.binaryStream.close()
        }
        
        parser.request()
        serializerStream.stream(to: self.serializer.stream(on: self.worker)).output(to: self.sink)
    }
    
    var nextMask: [UInt8]? {
        return self.server ? nil : randomMask()
    }
    
    public func send(string: String) {
        Data(string.utf8).withByteBuffer { bytes in
            let frame = Frame(op: .text, payload: bytes, mask: nextMask)
            self.serializerStream.next(frame)
        }
    }
    
    public func send(data: Data) {
        data.withByteBuffer { bytes in
            let frame = Frame(op: .binary, payload: bytes, mask: nextMask)
            self.serializerStream.next(frame)
        }
    }
    
    public func send(bytes: ByteBuffer) {
        let frame = Frame(op: .binary, payload: bytes, mask: nextMask)
        self.serializerStream.next(frame)
    }
    
    @discardableResult
    public func ping() -> Signal {
        let promise = Promise<Void>()
        let data = OSRandom().data(count: 32)
        
        self.pings[data] = promise
        
        data.withByteBuffer { bytes in
            let frame = Frame(op: .ping, payload: bytes, mask: nextMask)
            self.serializerStream.next(frame)
        }
        
        return promise.future
    }
    
    public func onData(_ run: @escaping (WebSocket, Data) throws -> ()) {
        self.binaryListener = { websocket, buffer in
            try run(websocket, Data(buffer: buffer))
        }
    }
    
    public func onByteBuffer(_ run: @escaping OnBinary) {
        self.binaryListener = run
    }

    public func onString(_ run: @escaping OnText) {
        self.textListener = run
    }
    
    public func onError(_ run: @escaping OnError) {
        self.errorListener = run
    }
    
    public func onClose(_ run: @escaping OnClose) {
        self.closeListener = run
    }
    
    /// Closes the connection to the other side by sending a `close` frame and closing the TCP connection
    public func close(_ data: Data = Data()) {
        data.withByteBuffer { bytes in
            let frame = Frame(op: .close, payload: bytes, mask: nextMask)
            self.serializerStream.next(frame)
            self.serializerStream.close()
        }
    }
}
