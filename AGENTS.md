# Overview

This is a LUA library which provides an automation testing framework for DFHack.

## Coding Conventions

- Avoid global variables.
- Prefix private members with an underscore.
- Use class-like tables to encapsulate state and behavior.
- Do not create copy-methods for class-like tables. Instead, the classes constructor should accept a table of values to initialize the instance.
- Avoid creating loose functions. Instead, define them as methods on a class-like table.
