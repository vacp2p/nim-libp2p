import results

func toOpt*[T](v: Opt[T] | T): Opt[T] =
  when v is T:
    Opt.some(v)
  else:
    v
