# Project management

Work for the MHK AWS platform is tracked with GitHub Issues and a GitHub Project board.

## Work item types

| Type  | Label        | Use for                                                        |
| ----- | ------------ | -------------------------------------------------------------- |
| Epic  | `type:epic`  | A large outcome. Stories are attached to it as **sub-issues**. |
| Story | `type:story` | User-facing work that fits in one sprint.                      |
| Task  | `type:task`  | Infra, chores, spikes.                                         |
| Bug   | `type:bug`   | Something broken in dev, qa or prod.                           |

Create items from the **New issue** page; each type has a form. To put a story under an
epic, open the epic and use **Create sub-issue** (or **Add existing issue**). The epic then
shows progress across its stories.

## Board

The project board tracks every issue through the `Stage` field:

`Backlog → Ready → In Dev → In Review → In QA → Ready to Deploy → Done`

Other fields: `Priority` (P0–P3), `Story Points`, `Environment`, and `Sprint` (iteration).

## Setup

`./bootstrap.sh` creates the labels, the project and its fields, and links the project to
this repo. It is safe to re-run. It needs `gh` logged in with the `project` scope as an
account that administers the repo.

Three things are done once in the project UI because the CLI does not cover them:

1. Add a `Sprint` field of type **Iteration** (Settings → Custom fields).
2. Create the views: a **Board** grouped by `Stage`, a **Table** grouped by parent issue
   (the epic view), and a **Current sprint** board filtered to `sprint:@current`.
3. Under Workflows, enable **Auto-add to project** for this repo and **Item closed → Done**.
