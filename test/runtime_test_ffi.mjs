import { Ok, Error } from "./gleam.mjs";

export function rescue(f) {
  try {
    f();
    return new Ok(undefined);
  } catch {
    return new Error(undefined);
  }
}
