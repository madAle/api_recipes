# Decisions

One file per design decision that someone reading the code could not work out
alone. A record states the decision as it stands today.

| Record | Status |
| --- | --- |
| [0001 Specs never use the network](0001-specs-never-use-the-network.md) | Accepted |
| [0002 CI runs on the maintained Ruby versions](0002-ci-runs-on-maintained-rubies.md) | Accepted |
| [0003 Releases and versioning](0003-releases-and-versioning.md) | Accepted |
| [0004 Scope of credentials](0004-credentials-scope.md) | Proposed |

## Writing a record

Name the file `NNNN-short-title.md` and use these sections:

- **Status**: Proposed, Accepted or Replaced by NNNN.
- **Decision**: what is done, in one or two sentences.
- **Why**: the reasons, and the options compared when there were several.
- **Consequences**: what this allows, costs or forbids.

When a decision changes, edit the record so that it describes the present. A
record replaced by another keeps only its status line and a link.
