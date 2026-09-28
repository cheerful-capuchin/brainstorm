## Prerequisites
- Create a new

## Context
For the demo version of our application, we cut some corners when it comes to the data retrieval, and we queried the clickhouse database straight away from the client application.
Now that the next milestone is to distribute the application to our clients, we need to provide a safe query layer.
Our client application is a fork of a VS Code in stxr-client-app.
It includes a big layer of the custom logic
