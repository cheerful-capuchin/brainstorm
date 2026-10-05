## Context

Based on Karpathy Tweet: https://x.com/karpathy/status/2105819303471976479
I want to create a skill that visualizes and explains the changes the agents have made.
I had a workflow that was running for 2 days to implement the strategy deployments and it wrote thousands
of lines of code. I don't want to review all of them, I want to have a proper explanation.
Let's try and follow the advice of Andrej and build something.

Tweet:
```
We'll be spending a lot more time trying to understand the outputs of language models. A few thoughts, tips & tricks:

Writing. Something I've had success with: Ask your LLM to explain something in ASD-STE100, it's a controlled language specification originally developed for aerospace maintenance documentation. LLMs well-versed in this language and it comes with heavy constraints on clean writing style that I often find a lot more readable. Sometimes I've tried to soften it a bit e.g. ask for "80% of the way to ASD-STE100" because the spec is quite stringent. But even better:

Diagrams / images. Instead of writing, ask your LLM to create a diagram. These can be a lot easier to process, parse, and understand. But even better:

Web pages. Ask for output "in HTML" to get a beautiful, interactive webpage. LLMs are getting really good at frontend and can create beautiful experiences, animations, etc. But even better:

Explainer videos. The output format I am most bullish on is fully custom / bespoke explainer videos generated on any arbitrary topic. Experiment with things like "Create a 3b1b style video explainer on X. Use my ElevenLabs API key for audio narration". (you'd need an API key for the latter or you can ask your LLM to find you decent free alternatives that use your local compute). This is actually starting to work!

In summary:
- As LLMs get better, they will do more and more of the legwork autonomously, and a lot more of our work will rise up the abstractions into oversight and understanding.
- Luckily, LLMs can help here too because as intelligence and code are increasingly abundant, you can ask for large, custom, discardable software artifacts (e.g. web apps, video explainers) that would have never made sense to create before. Push the boundaries here and you'll be surprised.
```

You can see the session file in brainstorm/sessions/SESS-00PE96K-strategy-deployments.md and all the commits made across the
submodules in my workspace.

What would be the appropriate way to display the information about the changes?
Do we need to integrate something like Clef (https://blog.cloudflare.com/clef-decision-models/) - a cloudflare classifier for
helping the LLM to figure out what's needed to be shown?



---
1. dev-env is fine as it's own git repo in stxr-prop org (use gh cli to create a github repo)
2. yes, no dev environment
3. unstaged (but collapsed by default), staged in a tree view, commit to commit, branch to branch. Yes, it should include all the git modules, and git only for now. I really like how intellij shows it in their commit tab
4. nah, I think for now all the git history. I think I'll just have a "create session" function that will attach the sess file. I don't think we need to do anything with the git commits. For now, everything in git is related to all the sessions.
5. I don't know or care. I should be able to view a nice diagram, a text block, a table, a code snippet and be able to execute the code snippet via the platform API.
   So, the agent writes the platform api function, I click run and then there should be some ui primitives to display the results.
   I think the best thing is for the function to take in the platform api, where it has something like ui().section, which is an id of a block where we'll render the ui element.
   For now, the ui elements can be text, blocks, and some pre-built primitives, like tables or lists.
   For example:
```typescript
function* run(platform: Platform.Trait) {
    let current = yield* platform.fs().current_dir();
    let fileHandle = yield* platform.fs().open(current, "database.sqlite");
    let db = yield* platform.sqlite().open({ database: fileHandle });
    let rows = yield* platform.sqlite().query(db, "");

    let table = yield* platform.ui().render_table(platform.ui().section, {});

    for (let row_data of rows) {
        let table_row = yield* platform.ui().render_row(table, {});
        yield* platfrom.ui().render_column(table_row, { })
        yield* platfrom.ui().render_column(table_row, { })
        yield* platfrom.ui().render_column(table_row, { })
        yield* platfrom.ui().render_column(table_row, { })
    }
}
```
6. I think we should be able to choose the directory, like a project in intellij.
7. I actually dunno what's the better solution here. Agent probably needs to be able to run the whole notebook once it's done with all the right creds in order to verify and that's when we'll render the data
8. Sure
9. Use heimdall style, but copy everything from there. Heimdall is just a reference, I don't want to share any packages, just copy what's needed
10. mentioned above
11. agree
12. I think every session in the project will have it's own directory where we can store all the relevant info. So, the `platform.fs().current_dir()` would be something like ~/work/stxr/workspace/.dev-env/data/sessions/{session_id}
13. I think we allow every host. For gcp we'll just have a different `platform.gcp().auth()`
14. How would you know that the secret was used? It then has to be all like pulumi `Output` monads, is there a way to not deal with all these wrapping objects?
15. I think we'll have an adapter that just reads the env variables and does ".to_lower_case()" on each variable. Somehow, I want to guard the access to the env variables and passcode or touch id seems the easiest one.
    There should also be the "always allow" option
16. once per run. Should have the session-wide "always allow" option
17. yes
18. all three
19. yes
20. yes
21. it's sqlite per session. I think there may be multiple notebooks in a session (sess-{id}), but only one sqlite file that includes the event log and the computed view
    I think the tauri application will have the unix socket or some kind of communication method that the agent can send the request to. The request must always include the session id
22. yeah, against the workspace root
23. disabled
24. no, no structure ui, it's an unrelated dev product
25. no charts for now
26. ~/.agents/skills and then symlink to workspace/.agents/skills and whatever each provider needs
