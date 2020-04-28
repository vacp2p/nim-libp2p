A stream can be one of:

- A source/producer - produces stuff
- A sink/consumer - consumes stuff produced by the source
- A duplex or producer and consumer - consumes from and external source and writes to an external source
- A transform/through - consumes a source, and produces another source, potentially modifying the piped data

A stream can be in these states:

- Producing
- Consuming
- Ended (EOF) or aborted
  - are this the same?
  - is Abort == EOF?
  - Should they be signaled by the same flags?
    - If different flags are used to signal EOF, should each be exposed or the stream simply reports EOF for each of the flags?
