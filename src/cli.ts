#!/usr/bin/env bun
import { main } from "./main";

process.exitCode = await main(Bun.argv.slice(2));
