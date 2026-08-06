# Overview

This is a LUA library which provides an automation testing framework for DFHack.

## Coding Conventions

- Adhere to the DRY principle (Don't Repeat Yourself).
- Adhere to the KISS principle (Keep It Stupid Simple), but not at the expense of clarity and good architecture/abstractions.
- Avoid global variables.
- Prefix private members with an underscore.
- Use class-like tables to encapsulate state and behavior.
- Do not create copy-methods for class-like tables. Instead, the classes constructor should accept a table of values to initialize the instance.
- Avoid creating loose functions. Instead, define them as methods on a class-like table.
