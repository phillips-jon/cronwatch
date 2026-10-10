---
title: Privacy
description: What cronwatch.dev collects, which is very little, and what happens to it.
updated: 2026-09-27
---

# Privacy

cronwatch.dev is the documentation site for an open source library. It has no accounts, no analytics, no advertising, and no tracking. This page lists everything it does collect.

## The library keeps its data with you

CronWatch runs inside your own application and stores job runs, output, and alerts in your own database. None of that is sent to cronwatch.dev or to the maintainer. If you connect it to an email service, Slack, or an AI provider, it talks to that service directly, under your account and its terms.

## Cookies and local storage

The site sets no cookies. If you switch between light and dark paper, your choice is saved in your browser's local storage under one key, `cronwatch-theme`, so the next page opens the same way. It never leaves your browser, and clearing your site data removes it.

The pages load their styles and scripts from cronwatch.dev itself. The fonts come from Adobe Fonts (use.typekit.net), which sees your IP address and browser when it serves them; nothing else is loaded from another site.

## Server logs

Like most web servers, the one behind cronwatch.dev writes a standard access log line for each request: your IP address, the time, the page requested, the response, the referring page, and your browser's user agent. The logs are used to keep the site running and to deal with abuse. They are kept for a limited time and then deleted, and they are not shared or used to build profiles.

## The contact form

When you use the [contact form](/contact/), your name, email address, and message are sent by email to the maintainer through Amazon Simple Email Service, along with the time, your IP address, and your user agent (to help spot abuse). The email address you give becomes the reply address. The contact service also logs one line per message (the time, your IP address and whether it was sent), without your name, address, or message.

Your message is used only to reply to you. It is not added to a mailing list, and it is not shared or sold. It stays in the maintainer's mailbox for as long as the conversation needs it.

## Other companies involved

- The hosting provider that runs the server cronwatch.dev lives on, where the server logs are stored.
- Amazon Web Services, which delivers contact form messages by email.
- GitHub, npm, and RubyGems, but only if you follow a link to them. They have their own privacy policies.

## Your choices

You can ask what the maintainer holds about you, or ask for your messages and any log lines about you to be deleted, through the [contact page](/contact/). You will get an answer by email.

## Changes and questions

If this page changes, the date at the top will too. Questions go to the [contact page](/contact/). cronwatch.dev is run by Jon C. Phillips.
