package storm.pex;

import com.intersystems.enslib.pex.BusinessOperation;
import com.intersystems.gateway.GatewayContext;
import com.intersystems.jdbc.IRISObject;

/** Optional, read-only formatter. No file, network, or durable effect in Java. */
public final class SafeHandoffOperation extends BusinessOperation {
    @Override
    public void OnInit() throws Exception {}

    @Override
    public void OnTearDown() throws Exception {}

    @Override
    public Object OnMessage(Object request) throws Exception {
        if (!(request instanceof IRISObject)) throw new IllegalArgumentException("Unexpected request");
        IRISObject in = (IRISObject) request;
        if (!"Storm.PexRequest".equals(in.invokeString("%ClassName", 1)))
            throw new IllegalArgumentException("Unexpected request class");
        String card = HandoffCard.render(in.getString("StormId"), in.getString("Groups"));
        IRISObject out = (IRISObject) GatewayContext.getIRIS()
            .classMethodObject("Storm.PexReply", "%New");
        out.set("Card", card);
        return out;
    }
}
