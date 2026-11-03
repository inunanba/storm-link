Class Storm.DemoProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="Storm.DemoProduction" LogGeneralTraceEvents="true">
  <Item Name="Storm.Service" ClassName="Storm.Service" PoolSize="0" Enabled="true"/>
  <Item Name="Storm.Process" ClassName="Storm.Process" PoolSize="1" Enabled="true"/>
  <Item Name="Storm.Agent" ClassName="Storm.AgentOperation" PoolSize="1" Enabled="true"/>
</Production>
}
}
