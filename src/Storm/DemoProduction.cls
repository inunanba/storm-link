Class Storm.DemoProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="Storm.DemoProduction" LogGeneralTraceEvents="true">
  <Item Name="Storm.Service" ClassName="Storm.Service" PoolSize="0" Enabled="true"/>
  <Item Name="Storm.Process" ClassName="Storm.Process" PoolSize="1" Enabled="true"/>
  <Item Name="Storm.WorkerOp" ClassName="Storm.WorkerOperation" PoolSize="1" Enabled="true">
    <Setting Target="Adapter" Name="HTTPServer">127.0.0.1</Setting>
    <Setting Target="Adapter" Name="HTTPPort">8088</Setting>
  </Item>
  <Item Name="Storm.Agent" ClassName="Storm.AgentOperation" PoolSize="1" Enabled="true"/>
  <Item Name="Storm.Review" ClassName="Storm.ReviewOperation" PoolSize="1" Enabled="true">
    <Setting Target="Host" Name="AutoCreateRole">0</Setting>
  </Item>
</Production>
}
}
