related to sess-00qkrbe

I want to build a dashboard with status pages for all the services we have with access to the cloud agent
that has a readonly access to our infra, so we can see what's going on in the system and
ask the agent questions.

I was thinking of copying the ideas from heimdall/README.md, where we have the programmatic access to the google cloud APIs.
I can deploy something like a pi agent or opencode to cloud run, I think, and assign a readonly service account to it.

However, I need some kind of password protection of some kind if there was inactivity for X mins, since the dashboard should be always
on and I don't want some cleaning staff to fuck around with it. Maybe even lock macmini with only showing the status page?

Maybe there are already built-in solutions we can use? If nothing is suitable, I think claude code can whip out a
simple app that handles this
