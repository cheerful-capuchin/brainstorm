In order to work efficiently with the codebase you need to have the following packages:
pnpm-workspace.yaml
```
packages:
  - application-server-client/ts # @structure/api-client
  - domain/ts/domain # @structure/domain
  - dsl-processor-core/ts # @structure/dsl-compiler
  - entity-core/packages/* # @structure/entity-core
  - ethereum/ts/* # @structure/ethereum-address
  - iam-core/ts
  - ipc/ts/* # @structure/http-client @structure/iam-core
  - market-info-core/ts
  - messaging/ts
  - runtime/ts
  - strategy-core/ts
  - telemetry/ts
  - ts-core/packages/* # @structure/assert, @structure/core @structure/fmt
  - workflow-core/ts
```
```
from:
- github.com/stxr-prop/application-server-client
- github.com/stxr-prop/domain
- github.com/stxr-prop/dsl-processor-core
- github.com/stxr-prop/entity-core
- github.com/stxr-prop/ethereum
- github.com/stxr-prop/iam-core
- github.com/stxr-prop/ipc
- github.com/stxr-prop/market-info-core
- github.com/stxr-prop/messaging
- github.com/stxr-prop/runtime
- github.com/stxr-prop/strategy-core
- github.com/stxr-prop/telemetry
- github.com/stxr-prop/ts-core
- github.com/stxr-prop/workflow-core
```
