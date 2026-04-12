pub type QueryCommand {
  QueryOne
  QueryMany
  QueryExec
  QueryExecResult
  QueryExecRows
  QueryExecLastId
}

pub type Value {
  SqlNull
  SqlString(String)
  SqlInt(Int)
  SqlFloat(Float)
  SqlBool(Bool)
  SqlBytes(BitArray)
}

pub fn null() -> Value {
  SqlNull
}

pub fn string(value: String) -> Value {
  SqlString(value)
}

pub fn int(value: Int) -> Value {
  SqlInt(value)
}

pub fn float(value: Float) -> Value {
  SqlFloat(value)
}

pub fn bool(value: Bool) -> Value {
  SqlBool(value)
}

pub fn bytes(value: BitArray) -> Value {
  SqlBytes(value)
}
