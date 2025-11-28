# Changesets

This directory contains changeset files for managing versions and changelogs.

## How to use

When you make changes to the SDK, create a changeset:

```bash
npm run changeset
```

Follow the prompts to describe your changes. This will create a new file in `.changeset/` directory.

The GitHub Action will automatically:
1. Create a "Version Packages" PR when changesets are detected
2. Publish to npm when that PR is merged
