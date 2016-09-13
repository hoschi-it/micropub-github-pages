# Micropub to GitHub Pages

[![Build Status](https://travis-ci.org/lildude/micropub-github-pages.svg?branch=master)](https://travis-ci.org/lildude/micropub-github-pages) [![Coverage Status](https://coveralls.io/repos/github/lildude/micropub-github-pages/badge.svg)](https://coveralls.io/github/lildude/micropub-github-pages)

A simple endpoint that accepts [Micropub](http://micropub.net/) requests and creates and publishes a Jekyll/GitHub Pages post to a configured GitHub repository.  This project is inspired by [Micropub to GitHub](https://github.com/voxpelli/webpage-micropub-to-github), a Node.js implementation.

## Setup

[Scripts to Rule Them All](http://githubengineering.com/scripts-to-rule-them-all/) is part of my day-to-day job and I really like the idea, so that's what I use here too.

Just run `script/bootstrap` and you're get all the gem bundle goodness happening for you.

### Heroku

Clicky the button that will appear right :point_right: :soon:

### Elsewhere

Run `script/server` and you'll have the application running on http://localhost:4567 .

## Configuration

Copy `config-example.yml` to `config.yml` and customise to your :heart:'s content.

## Testing

Run `script/test` to run through the full test suite.

## License

Micropub to GitHub Pages is licensed under the MIT License - see the LICENSE.md file for details
