ensure there is a session file

The activity worker had an expired github token on Sunday, and no one was notified about this.
Neither by the activity worker NOR by the failed workflow in the workflow engine.

I think we need alerting in both. Otherwise, it's a silent failure
