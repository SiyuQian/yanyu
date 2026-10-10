// Only the Bun APIs used by this standalone tool. No dependency installation is needed.
interface ImportMeta {
  readonly dir: string;
  readonly main: boolean;
}
declare const Bun: {
  build(options: {
    entrypoints: string[];
    target: "browser";
    write: boolean;
  }): Promise<{ success: boolean; outputs: { text(): Promise<string> }[] }>;
  file(path: string): Blob;
  serve(options: {
    hostname: string;
    port: number;
    fetch(request: Request): Promise<Response>;
    error(): Response;
  }): { port: number; stop(force?: boolean): void };
};
declare module "bun:sqlite" {
  export class Database {
    constructor(path: string, options?: { readonly: boolean });
    run(sql: string, params?: (string | number | null)[]): void;
    query(sql: string): { all(): unknown[] };
    close(): void;
  }
}
declare module "bun:test" {
  export const describe: (name: string, callback: () => void) => void;
  export const test: (
    name: string,
    callback: () => void | Promise<void>,
    timeout?: number,
  ) => void;
  export const expect: (actual: unknown) => {
    toBe(expected: unknown): void;
    toEqual(expected: unknown): void;
    toHaveLength(expected: number): void;
    toBeNull(): void;
    toThrow(): void;
  };
}
