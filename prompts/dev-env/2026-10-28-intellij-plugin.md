ensure there is a session file created
I have this app "dev-env" in ~/work/stxr/dev-env
The primary goal is to have a "notebook" feature that I can ask the agent
to craft me to explain the concepts.
So, I have the session file and then I open all the notebooks attached to it.
Sometimes those notebooks include the scripts with the platform API that
do some work.

I wonder if I can use IntelliJ and RustRover as the host and write my notebook feature
as a plugin?

I want to be able to leave the annotations, view mermaid, have the platfrom API, view the git changes.
I really like the intellij git client, I just want to be able to highlight changes and send the comment to
the agent

How feasible is it to write the intellij plugin? How would the platform API code will be evaluated there?
Can I leave annotations for git changes and the notebooks?
