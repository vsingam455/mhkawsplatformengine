#!/usr/bin/env bash
# Creates the labels and the GitHub Project board for this repo.
# Safe to re-run: labels are upserted, and the project is only created if missing.
#
# Requires: gh logged in as an account with admin on the repo and the
# 'project' scope (gh auth refresh -s project).
set -euo pipefail

OWNER="${OWNER:-vsingam455}"
REPO="${REPO:-mhkawsplatformengine}"
PROJECT_TITLE="${PROJECT_TITLE:-MHK Projects}"

label() { gh label create "$1" --repo "$OWNER/$REPO" --color "$2" --description "$3" --force >/dev/null; echo "label: $1"; }

label "type:epic"     "5319E7" "Large body of work, broken into stories as sub-issues"
label "type:story"    "1D76DB" "User-facing work that fits in one sprint"
label "type:task"     "C5DEF5" "Technical or operational work"
label "type:bug"      "D73A4A" "Something is broken"
label "priority:p0"   "B60205" "Drop everything"
label "priority:p1"   "D93F0B" "This sprint"
label "priority:p2"   "FBCA04" "Next sprint or two"
label "priority:p3"   "0E8A16" "Backlog"
label "env:dev"       "BFDADC" "Affects or targets dev"
label "env:qa"        "BFDADC" "Affects or targets qa"
label "env:prod"      "BFDADC" "Affects or targets prod"
label "blocked"       "000000" "Cannot progress, see comments"

number=$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title==\"$PROJECT_TITLE\") | .number" | head -1)
if [ -z "$number" ]; then
  number=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json --jq .number)
  echo "project: created #$number"

  # Columns use the built-in Status field so GitHub's own workflows (closed -> Done) and the agents agree.
  status_id=$(gh project field-list "$number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status").id')
  # shellcheck disable=SC2016  # $f is a GraphQL variable, not a shell one
  gh api graphql -f f="$status_id" -f query='mutation($f:ID!){updateProjectV2Field(input:{fieldId:$f,singleSelectOptions:[
    {name:"Backlog",color:GRAY,description:"Not yet scheduled"},
    {name:"Ready",color:BLUE,description:"Refined and ready to start"},
    {name:"In Dev",color:YELLOW,description:"Being implemented by a person or the dev agent"},
    {name:"In Review",color:ORANGE,description:"Pull request open"},
    {name:"In QA",color:PURPLE,description:"Deployed to dev, being tested"},
    {name:"Ready to Deploy",color:PINK,description:"Tested, waiting for promotion"},
    {name:"Done",color:GREEN,description:"Released"}]}){clientMutationId}}' >/dev/null
  gh project field-create "$number" --owner "$OWNER" --name "Priority" --data-type SINGLE_SELECT \
    --single-select-options "P0,P1,P2,P3" >/dev/null
  gh project field-create "$number" --owner "$OWNER" --name "Story Points" --data-type NUMBER >/dev/null
  gh project field-create "$number" --owner "$OWNER" --name "Environment" --data-type SINGLE_SELECT \
    --single-select-options "dev,qa,prod" >/dev/null
  echo "project: fields created"
else
  echo "project: #$number already exists, leaving fields alone"
fi

gh project link "$number" --owner "$OWNER" --repo "$OWNER/$REPO" >/dev/null || true
echo "done: $(gh project view "$number" --owner "$OWNER" --format json --jq .url)"
