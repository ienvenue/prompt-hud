# Security Policy

Prompt HUD asks for macOS Accessibility permission so it can find the text cursor, read selected text and paste. Please report anything that could let other apps, web pages or files misuse that.

## Supported versions

Only the [latest release](https://github.com/ienvenue/prompt-hud/releases/latest) receives fixes.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately instead:

1. Go to the [Security tab](https://github.com/ienvenue/prompt-hud/security) of this repository.
2. Click **Report a vulnerability** and describe the problem and how to reproduce it.

You can expect a first reply within 7 days. Once a fix is released, you'll be credited in the changelog unless you'd rather not be.

## Scope

In scope, for example:

- A `prompthud://` link that saves or changes prompts without your confirmation.
- Prompt HUD inserting text into an app or field you didn't choose.
- Data leaving your Mac. Prompt HUD should never connect to the internet.

Out of scope: problems that need someone who already controls your Mac, and macOS's own warning for apps that aren't notarized.
