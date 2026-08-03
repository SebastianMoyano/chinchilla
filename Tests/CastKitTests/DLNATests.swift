import Foundation
import Testing
@testable import CastKit

@Test func parsesDeviceDescription() {
    let xml = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
    <device>
      <friendlyName>Living Room TV</friendlyName>
      <modelDescription>Samsung QLED</modelDescription>
      <serviceList>
        <service>
          <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
          <controlURL>/upnp/control/AVTransport1</controlURL>
        </service>
        <service>
          <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
          <controlURL>/upnp/control/RenderingControl1</controlURL>
        </service>
      </serviceList>
    </device>
    </root>
    """
    #expect(UPnPDescription.value(of: "friendlyName", in: xml) == "Living Room TV")
    let services = UPnPDescription.blocks(named: "service", in: xml)
    #expect(services.count == 2)
    #expect(services[0].contains("AVTransport"))
}

@Test func ssdpHeaderExtraction() {
    let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.50:9197/dmr\r\nST: upnp:rootdevice\r\n\r\n"
    #expect(SSDP.header("LOCATION", in: response) == "http://192.168.1.50:9197/dmr")
    #expect(SSDP.header("MISSING", in: response) == nil)
}

@Test func dlnaTimeFormatsRoundTrip() {
    #expect(DLNAControl.timeString(3725) == "1:02:05")
    #expect(DLNAControl.seconds(from: "1:02:05") == 3725)
    #expect(DLNAControl.seconds(from: "garbage") == 0)
}

@Test func didlMetadataIsEscapedOnce() {
    let didl = DLNAControl.didl(title: "My Movie & Friends", url: "http://x/y.mp4", mime: "video/mp4")
    // The whole DIDL is XML-escaped for embedding in the SOAP envelope.
    #expect(didl.contains("&lt;DIDL-Lite"))
    #expect(didl.contains("My Movie &amp;amp; Friends"))
}
