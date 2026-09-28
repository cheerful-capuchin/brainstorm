set default-list := true

# Create a session record in progress/ and print its path.
# `related` is a comma-separated list of session IDs.
[arg("slug", long)]
[arg("title", long)]
[arg("related", long)]
session slug title related="":
    @python3 scripts/new_session.py --slug {{quote(slug)}} --title {{quote(title)}} --related {{quote(related)}}

sync message="sync":
    jj describe -m "{{message}}" # todo: add the datetime
    jj bookmark set main -r @
    jj git push

