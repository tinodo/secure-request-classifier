# Networking model

This document explains every networking decision in the demo and why it is not optional.

## The three subnets

| Subnet | Network | Delegated to | NSG | Size in the demo | Why |
| --- | --- | --- | --- | --- | --- |
| `snet-powerplatform` | primary **and** failover | `Microsoft.PowerPlatform/enterprisePolicies` | yes | `/24` | Where Power Platform runs the connector containers |
| `snet-functions` | primary only | `Microsoft.App/environments` | yes | `/26` | Function App outbound virtual network integration |
| `snet-private-endpoints` | primary only | *(none)* | yes | `/27` | Private endpoints for the Function App and storage |

These cannot be merged. Three separate reasons:

* **A delegated subnet is exclusive.** Microsoft: *"you can use an existing virtual network for Power Platform, if you delegate a single, new subnet within the virtual network specifically to Power Platform. You must dedicate the delegated subnet for subnet delegation and can't use it for other purposes."* ([VNet support overview](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview))
* **Flex Consumption uses a different delegation.** Microsoft: *"The subnet delegation required by Flex Consumption apps is `Microsoft.App/environments`."* ([Flex Consumption plan](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan)). That is not the same service name as Power Platform's, and a subnet can carry only one delegation.
* **Private endpoints cannot live in a delegated subnet.** ([Subnet delegation overview](https://learn.microsoft.com/en-us/azure/virtual-network/subnet-delegation-overview))

### Subnet sizing

Microsoft's guidance for the Power Platform delegated subnet: *"allocate 25 to 30 IPs for production environments and 6 to 10 IPs for nonproduction environments"*, plus *"Each subnet reserves five IP addresses"*. A `/24` is the size used in every Microsoft example and leaves room to add environments later.

Two constraints worth knowing before you pick a range:

* If you use more than one delegated subnet, **both must have the same number of available IP addresses**.
* **The range is immutable after delegation.** Changing it requires `Disable-SubnetInjection` first, and Microsoft support to change the range while it is delegated.

For `snet-functions`, Flex Consumption requires a minimum of `/27`; `/26` is recommended when scaling beyond a single app.

Subnet names must not contain underscores — an Azure Functions virtual network integration requirement.

## Network security groups

Every subnet carries a network security group. This is not optional hardening — it is a hard
requirement in most governed subscriptions.

Azure Landing Zones assign **`Deny-Subnet-Without-Nsg`** at the `landingzones` management group.
It is a `Deny` effect, and it evaluates the whole virtual network resource, so a template that
creates any subnet without an NSG fails outright:

```
RequestDisallowedByPolicy: Resource 'vnet-...' was disallowed by policy.
Reasons: 'Subnets {enforcementMode} have a Network Security Group.'
policyDefinitionName: Deny-Subnet-Without-Nsg
```

This was found by validating this exact template against a real ALZ-governed subscription, not
by reading the policy catalogue.

The rules in `infra/modules/network-security-group.bicep` are deliberately **explicit rather
than restrictive**:

| Subnet role | Direction | Rule |
| --- | --- | --- |
| `powerPlatform` | Outbound | HTTPS to `VirtualNetwork` (reaches the private endpoints) |
| `powerPlatform` | Outbound | HTTPS to `AzureCloud` (Power Platform control plane) |
| `functions` | Outbound | HTTPS to `VirtualNetwork` (storage private endpoints) |
| `functions` | Outbound | HTTPS to `AzureCloud` (Azure Monitor ingestion) |
| `privateEndpoints` | Inbound | HTTPS from the virtual network address space |

No blanket deny rule is added. Azure's default rules already permit intra-VNet traffic and
outbound internet access, and Microsoft states that Power Platform containers in a delegated
subnet require outbound connectivity. Adding a deny-all would satisfy the policy and then break
the demo in a way that is genuinely tedious to diagnose — the connector would fail with a
timeout rather than a clear error.

NSGs on a delegated subnet are explicitly supported. From the Power Platform virtual network
whitepaper: *"Customers can associate NSGs with the delegated subnet. Define and enforce
security rules to control inbound and outbound traffic to and from the subnet."*

To restrict egress further, attach a NAT gateway or a route table to `snet-powerplatform`. Note
that NSGs alone do not change the egress path — see "Egress from the delegated subnet" below.

## Region pairing

This is the single most commonly missed requirement.

A Power Platform *geography* maps to **two** Azure regions, and a Power Platform environment can move between them without any customer action. Microsoft:

> If two or more supported regions exist for the geography, such as the United States with eastus and westus, you need two virtual networks in *different* regions to create the enterprise policy. This requirement applies to both production and nonproduction environments.
> — [Set up VNet support](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure)

and:

> Power Platform infrastructure is built to use a primary and a failover region without explicit action by the customer… To achieve the best resilience, set up a virtual network in both paired Azure regions and establish a peering connection between them.
> — [Secure access to Azure resources](https://learn.microsoft.com/en-us/power-platform/architecture/reference-architectures/secure-access-azure-resources)

`infra/main.bicep` encodes the documented mapping and derives both regions from the `powerPlatformRegion` parameter:

| Power Platform geography | Primary | Failover |
| --- | --- | --- |
| `unitedstates` | eastus | westus |
| `europe` | westeurope | northeurope |
| `uk` | uksouth | ukwest |
| `asia` | eastasia | southeastasia |
| `australia` | australiasoutheast | australiaeast |
| `japan` | japaneast | japanwest |
| `india` | centralindia | southindia |
| `canada` | canadacentral | canadaeast |
| `france` | francecentral | francesouth |
| `germany` | germanynorth | germanywestcentral |
| `switzerland` | switzerlandnorth | switzerlandwest |
| `southafrica` | southafricanorth | southafricawest |
| `korea` | koreasouth | koreacentral |
| `norway` | norwaywest | norwayeast |
| `southamerica` | brazilsouth | *(single region)* |
| `unitedarabemirates` | uaenorth | *(single region)* |
| `singapore` | southeastasia | *(single region)* |
| `sweden` | swedencentral | *(single region)* |
| `italy` | italynorth | *(single region)* |

Single-region geographies deploy one virtual network and no peering; the template handles that automatically.

To confirm which region your environment is actually in:

```powershell
Install-Module Microsoft.PowerPlatform.EnterprisePolicies
Get-EnvironmentRegion -EnvironmentId <environment-id>
```

The `location` on the enterprise policy resource is a Power Platform **geography name**, not an Azure region — `europe`, not `westeurope`. A few geographies use a different string on the policy than on the environment (`uk`, `uae`, `brazil`); `main.bicep` maps these.

## DNS

This is the second most commonly missed requirement.

Power Platform resolves host names using the DNS configured on the virtual network that hosts the delegated subnet:

> Yes. Power Platform uses the custom DNS you configure in the virtual network that holds the delegated subnet to resolve all endpoints.
> — [VNet support overview, FAQ](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview)

> The request initiates from your delegated subnet, and tries to resolve the hostname by using the DNS server that's configured for your virtual network.
> — [Troubleshoot Power Platform virtual network support](https://learn.microsoft.com/en-us/troubleshoot/power-platform/administration/virtual-network)

With Azure-provided DNS, that means **Azure Private DNS zones linked to that virtual network** are authoritative. Microsoft's own worked example in the troubleshooting article is a failure caused by linking the zone to only one of the two regional networks.

Therefore `infra/modules/private-dns-zone.bicep` links every zone to **every** virtual network in the demo:

| Zone | Used by |
| --- | --- |
| `privatelink.azurewebsites.net` | Function App private endpoint (covers both the app host and its `scm` host) |
| `privatelink.blob.core.windows.net` | Storage — deployment package and host blobs |
| `privatelink.queue.core.windows.net` | Storage — Functions host queues |
| `privatelink.table.core.windows.net` | Storage — Functions host tables |

Two notes on the App Service zone:

* One private endpoint with `groupId: sites` covers both `<app>.azurewebsites.net` and `<app>.scm.azurewebsites.net`. There is no separate `scm` sub-resource.
* **Do not create `scm.privatelink.azurewebsites.net` as a separate zone.** Microsoft: *"If you use private DNS zones in Azure, don't deploy this as an additional zone."* ([Private endpoint DNS](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)) The private DNS zone group adds the `scm` A record automatically.

The VNet DNS server setting is also immutable while subnet injection is active — changing it requires `Disable-SubnetInjection`, a 30-minute wait, and `Enable-SubnetInjection`.

## Peering

The primary and failover networks are peered bidirectionally with `allowVirtualNetworkAccess: true`. Gateway transit and forwarded traffic are both off — the demo needs neither, and leaving them off keeps the topology inert from a hub's point of view.

Peering matters because the private endpoints live only in the primary network. Without it, a connector container that starts in the failover region would resolve the private IP address correctly and then fail to route to it.

## Egress from the delegated subnet

By default, containers in the delegated subnet have unrestricted outbound internet access. Microsoft is explicit that restricting it is a customer responsibility, and that network security groups alone are not enough:

> If only configuring network security groups, without configuring the next hop (that is, attaching a NAT Gateway or adding a custom routing table) traffic is restricted according to the rules specified. However, internet-bound traffic will still egress from Power Platform owned IP addresses.
> — [Power Platform virtual network support whitepaper](https://learn.microsoft.com/en-us/power-platform/admin/virtual-network-support-whitepaper)

This demo attaches a network security group to **every** subnet, because Azure Landing Zones
assign `Deny-Subnet-Without-Nsg` as a `Deny` effect and the deployment simply fails without one
(see "Network security groups" above). The rules are explicit but permissive: they document the
flows the demo uses without overriding Azure's defaults.

It deliberately does **not** attach a NAT gateway or route table. Adding one would be a
legitimate hardening step but would also make the demo's failure modes harder to explain, and
the requirement here was an isolated workload that coexists with governance rather than one that
reimplements it.

## TLS

Power Platform requires the target endpoint to present a full certificate chain from a publicly trusted CA:

> Power Platform requires the endpoint to present a TLS certificate with the complete chain. You can't add your custom root CA to the list of well-known CAs.

`*.azurewebsites.net` satisfies this out of the box. If you front the Function App with a custom domain, the certificate must chain to a public root.

## What the traffic actually looks like

1. The flow's `InvokeHttp` action executes in a container inside `snet-powerplatform`.
2. That container resolves `func-xxxx.azurewebsites.net`. Azure-provided DNS consults `privatelink.azurewebsites.net`, which is linked to the network, and returns the private endpoint's address (for example `10.60.2.4`).
3. The container opens TLS to `10.60.2.4:443` and sends the request with a Microsoft Entra ID bearer token.
4. Private Link delivers it to the Function App. App Service Authentication validates the token before the worker sees the request.
5. The Function App's own outbound traffic (storage, Application Insights) leaves through `snet-functions` and reaches storage over its private endpoints.

No part of that path traverses the public internet, and no part of it is reachable from the public internet.
