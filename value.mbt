///|
/// A JSON-shaped semantic value. Requests and reports travel as these; object
/// key order is never significant, and numbers are finite doubles.
pub(all) enum Value {
  Null
  Bool(Bool)
  Number(Double)
  String(String)
  Array(Array[Value])
  Object(Map[String, Value])
} derive(Eq, @debug.Debug)

///|
pub extend Value with Eq::{equal, not_equal}

///|
pub extend Value with @debug.Debug::{to_repr}

///|
pub fn from_json(value : Json) -> Value {
  match value {
    Json::Null => Null
    Json::True => Bool(true)
    Json::False => Bool(false)
    Json::Number(n, ..) => Number(n)
    Json::String(s) => String(s)
    Json::Array(items) => Array(items.map(from_json))
    Json::Object(fields) => Object(fields.map(fn(_, v) { from_json(v) }))
  }
}

///|
pub fn Value::to_json(self : Value) -> Json {
  match self {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Number(n) => Json::number(n)
    String(s) => Json::string(s)
    Array(items) => Json::array(items.map(fn(v) { v.to_json() }))
    Object(fields) => Json::object(fields.map(fn(_, v) { v.to_json() }))
  }
}

///|
/// Character-lexical key order, so a report hashed or compared across backends
/// and languages always spells the same.
pub fn Value::canonical(self : Value) -> String {
  match self {
    Object(fields) => {
      let keys = fields.keys().collect()
      keys.sort_by(fn(a, b) { lexical_compare(a, b) })
      "{" +
      keys
      .map(fn(k) {
        String(k).to_json().stringify() + ":" + fields[k].canonical()
      })
      .join(",") +
      "}"
    }
    Array(items) => "[" + items.map(fn(v) { v.canonical() }).join(",") + "]"
    _ => self.to_json().stringify()
  }
}

///|
fn lexical_compare(left : String, right : String) -> Int32 {
  let a = left.to_array()
  let b = right.to_array()
  let size = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<size {
    if a[i] < b[i] {
      return -1
    }
    if a[i] > b[i] {
      return 1
    }
  }
  a.length() - b.length()
}

///|
pub(all) suberror InputError {
  InputError(String)
} derive(Eq, @debug.Debug)

///|
pub extend InputError with Eq::{equal, not_equal}

///|
pub extend InputError with @debug.Debug::{to_repr}

///|
pub impl Show for InputError with fn output(self, logger) {
  let InputError(message) = self
  logger.write_string(message)
}

///|
pub extend InputError with Show::{to_string, output}

///|
pub fn get(value : Value, key : String) -> Value {
  match value {
    Object(fields) => fields.get(key).unwrap_or(Null)
    _ => Null
  }
}

///|
pub fn field(value : Value, key : String) -> Value {
  get(value, key)
}

///|
pub fn has(value : Value, key : String) -> Bool {
  match value {
    Object(fields) => fields.contains(key)
    _ => false
  }
}

///|
pub fn required(value : Value, key : String) -> Value raise InputError {
  if !has(value, key) {
    raise InputError("missing field: " + key)
  }
  field(value, key)
}

///|
pub fn str(value : Value) -> String raise InputError {
  match value {
    String(s) => s
    _ => raise InputError("expected string")
  }
}

///|
pub fn optional_str(
  value : Value,
  fallback : String,
) -> String raise InputError {
  match value {
    Null => fallback
    _ => str(value)
  }
}

///|
pub fn arr(value : Value) -> Array[Value] raise InputError {
  match value {
    Array(items) => items
    _ => raise InputError("expected array")
  }
}

///|
pub fn obj(value : Value) -> Map[String, Value] raise InputError {
  match value {
    Object(fields) => fields
    _ => raise InputError("expected object")
  }
}

///|
pub fn num(value : Value) -> Double raise InputError {
  match value {
    Number(n) if !n.is_nan() && !n.is_inf() => n
    _ => raise InputError("expected finite number")
  }
}

///|
pub fn optional_num(
  value : Value,
  fallback : Double,
) -> Double raise InputError {
  match value {
    Null => fallback
    _ => num(value)
  }
}

///|
pub fn record(fields : Array[(String, Value)]) -> Value {
  let result : Map[String, Value] = Map([])
  for (key, value) in fields {
    result[key] = value
  }
  Object(result)
}

///|
pub fn strings(items : Array[String]) -> Value {
  Array(items.map(fn(s) { String(s) }))
}

///|
pub fn fields_only(
  value : Value,
  allowed : Array[String],
) -> Unit raise InputError {
  for key, _ in obj(value) {
    if !allowed.contains(key) {
      raise InputError("unknown field: " + key)
    }
  }
}
