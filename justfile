set shell := ["sh", "-cu"]

default:
  @just --list

deps:
  gleam deps download

format:
  gleam format src/ test/

format-check:
  gleam format --check src/ test/

check:
  gleam check

build:
  gleam build --warnings-as-errors

test:
  gleam test

shellspec:
  shellspec

all:
  gleam format --check src/ test/
  gleam check
  gleam build --warnings-as-errors
  gleam test
  shellspec
