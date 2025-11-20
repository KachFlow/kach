set dotenv-load
set positional-arguments

# List available recipes
default:
  @just --list

# ------------------------------------ General ------------------------------------

# Delete all git branches except for main
clean-branches:
  git branch | grep -v -E "(main)" | xargs git branch -D

# Format project
format:
  # todo

# Run tests
test:
  # todo

# ------------------------------------ Docs ------------------------------------
[working-directory: 'docs']
docs:
	bun --bun run dev
