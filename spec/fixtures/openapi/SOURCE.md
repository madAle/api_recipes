# Where the descriptions in this folder come from

| File | Origin |
| --- | --- |
| `github.json.gz` | the OpenAPI 3.0 description of the GitHub REST API, compressed with gzip: `descriptions/api.github.com/api.github.com.json` of [github/rest-api-description](https://github.com/github/rest-api-description), commit `4754642742db86eba8971da648439698b46ac2ec` (13 November 2026), version 1.1.4 of the description. MIT license, copyright GitHub. SHA-256 of the file before compression: `f7a3de68869181d34b232d88840d31f8157ade45cad1746eaab90cd3c801b31c` |
| `github_small.yml`, `github_small.expected.yml` | written for the specs: the seven operations of the example in the documentation, and the recipe they become |

`github.json.gz` is the large real description that `api_recipes import` is
tried against. It is used by `spec/integration/import_real_description_spec.rb`
only and is not part of the gem package.
