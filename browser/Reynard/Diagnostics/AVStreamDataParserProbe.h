//
//  AVStreamDataParserProbe.h
//  Reynard
//
//  See the .m for what this answers and why it exists.
//
//  Safe to call more than once - it runs at most once per process.
//  Main thread, at launch. It never blocks: the one thing that earns a
//  scene-update watchdog kill is holding the main thread, and the
//  parser's callbacks log themselves whenever they arrive.
//

#ifndef AVStreamDataParserProbe_h
#define AVStreamDataParserProbe_h

void ReynardRunAVStreamDataParserProbe(void);

#endif /* AVStreamDataParserProbe_h */
