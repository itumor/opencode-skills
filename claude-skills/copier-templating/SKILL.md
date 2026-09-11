---
name: copier-templating
description: Generic Copier project-templating usage — copier.yml question schema (type, choices, when, validator), Jinja templating in _templates_suffix files, .copier-answers.yml tracking, copier copy vs copier update, migrations, and custom delimiters for target languages whose native syntax clashes with Jinja's {{ }}. Use whenever the user mentions Copier, "copier update", a project scaffolded from a template that needs a new question added, a copier.yml file, .copier-answers.yml, or scaffolding a new repo/client/service from an existing template — even if they just say "our template generator" or "the thing that stamps out new client repos." Not tied to any one company's specific templates; for EIS/OneSuite's ansible or clusters Copier templates, prefer this repo's own eis-ansible-project-template / argocd-clusters-template-change skills first.
---

# Copier templating

Copier turns a source directory of Jinja-templated files into a generated project, then remembers the answers so the generated project can be re-synced (`copier update`) when the template evolves — this is its key difference from a one-shot generator like `cookiecutter` or `yeoman`.

## Core files

- **`copier.yml`** (template root): the question schema — what's asked, in what order, with what type/default/validation.
- **`.copier-answers.yml`** (generated project root): written into every generated project, records the template source, the `_commit` (git ref) it was rendered from, and every answer given. `copier update` reads this file to know what changed since last render — never hand-edit the `_commit` field, always let `copier update` manage it.
- **`{{ _copier_conf.answers_file }}.jinja`** or a plain `.copier-answers.yml.jinja`: the template that emits the answers file itself — usually copier scaffolds this automatically, but a custom one can add extra bookkeeping fields.

## copier.yml question schema

```yaml
project_name:
  type: str
  help: "Name of the new project"

environment:
  type: str
  choices: ["dev", "uat", "prod"]
  default: "dev"

enable_monitoring:
  type: bool
  default: true

region:
  type: str
  when: "{{ environment == 'prod' }}"   # only asked when the condition is true
  default: "us-east-1"

_subdirectory: template          # if the template lives in a subdir of the repo
_envops:
  block_start_string: "[%"       # custom delimiters — see below
  block_end_string: "%]"
  variable_start_string: "[["
  variable_end_string: "]]"
```

- `when:` makes a question conditional on prior answers — use this instead of asking everything and post-filtering, since an answer that's `when:false` becomes unrepresentable (not just unused) and downstream logic can safely assume it's absent.
- A `validator:` field (Jinja expression that must render empty string to pass) catches bad input before generation, not after.
- Questions starting with `_` are Copier settings (`_subdirectory`, `_envops`, `_min_copier_version`, `_exclude`, `_skip_if_exists`, `_tasks` for post-generation commands), not prompts shown to the user.

## Custom delimiters — the recurring gotcha

Copier's default Jinja delimiters are `{{ }}` / `{% %}`. Any templated file whose *own* language already uses `{{ }}` (Ansible, Helm/Go templates, Terraform's `${}` is usually fine but some HCL patterns aren't) will collide — Copier tries to render the target file's own template syntax as if it were Copier's.

Fix: set `_envops` with alternate delimiters (`[% %]` / `[[ ]]` is a common convention) globally in `copier.yml`, or per-file via `_templates_suffix` and matching `[[ _envops ]]` blocks, or exclude specific files from templating with `_exclude` when they should be copied byte-for-byte.

## copier copy vs copier update

- **`copier copy <template> <dest>`**: fresh generation, no `.copier-answers.yml` assumed to exist. Use for a brand-new project.
- **`copier update`** (run inside an already-generated project): re-renders using the new template version, replaying prior answers, and 3-way-merges the diff against any hand-edits the project made since. This is where most real friction lives:
  - A file the generated project hand-edited *and* the template also changed will produce conflict markers — resolve like a git merge.
  - New questions added to the template (without a `default:`) will interactively prompt during `update`, which breaks non-interactive CI update jobs — always give new questions a sensible default, or gate them behind `when:` so old projects skip them.
  - Renamed or restructured template files can look like "delete + add" to the merge algorithm and lose local edits silently — a migration script (`_migrations:` in `copier.yml`) can run arbitrary commands before/after the update to handle renames explicitly.

## Migrations

```yaml
_migrations:
  - version: v2.0.0
    before:
      - "mv old_config.yml new_config.yml"
```

Migrations run once, keyed to crossing a specific template version boundary — use them for anything `copier update`'s diff/merge can't express on its own (renames, schema-breaking answer transforms).

## Debugging a broken render

1. `copier copy --pretend <template> <dest>` — dry-run, shows what would be generated without writing files.
2. Check `.copier-answers.yml` in a generated project for the actual `_commit` it's pinned to — a "the template doesn't have that yet" bug is often just an old pin.
3. If a question's `when:` isn't behaving, remember conditions evaluate top-to-bottom in file order using *already-answered* values — a `when:` referencing a question defined later in the file will error or silently see it as undefined.
