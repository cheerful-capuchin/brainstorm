Ensure there is a session file (decision log skill)

I have the github managed in pulumi in infra/infra/github.ts
The issue there is the teams and git dependencies.
The moment a repo adds a new internal repo, I need to ensure that that repo belongs to the necessary github team.
Otherwise, I have to manually manage it all the time, which sucks.

How would you automate the process of the dependency resolution, so that I get everything resolved and added to lists?
When managing repos, I think in terms of projects and teams, not individual github repositories.
What's the way to simplify this model, where I can just say that member a, b, c belong to project "backtest"
Ideally, I would like a very compact list at the top of the file that shows that and internally it resolves all the permissions and dependencies, etc.
I just assign the member, their permission scope and that's it.
