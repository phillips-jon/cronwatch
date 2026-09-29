//! `Serialize` and `Deserialize` for the public types (the `serde` feature),
//! for an app's own use: returning a `JobSummary` from its own handler,
//! say. Each type goes through the same JSON value its `to_json` writes, so
//! the fields, their names and their order are the SDK's; numbers that are
//! whole are written as integers, as JavaScript prints them. The stores and
//! channels never use this.

use std::fmt;

use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::ser::{SerializeMap, SerializeSeq};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::js::{Object, Value};
use crate::types::{
    Alert, AlertType, CheckResult, Condition, Definition, JobHealth, JobState, JobSummary, Metrics, Run, RunStatus,
};

/// The largest whole number a double holds exactly, 2^53.
const SAFE: f64 = 9_007_199_254_740_992.0;

impl Serialize for Value {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Value::Null => s.serialize_unit(),
            Value::Bool(b) => s.serialize_bool(*b),
            // JSON.stringify writes a number that is not finite as null.
            Value::Number(n) if !n.is_finite() => s.serialize_unit(),
            Value::Number(n) if n.fract() == 0.0 && n.abs() <= SAFE => s.serialize_i64(*n as i64),
            Value::Number(n) => s.serialize_f64(*n),
            Value::String(text) => s.serialize_str(text),
            Value::Array(list) => {
                let mut seq = s.serialize_seq(Some(list.len()))?;
                for v in list {
                    seq.serialize_element(v)?;
                }
                seq.end()
            }
            Value::Object(o) => o.serialize(s),
        }
    }
}

impl Serialize for Object {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut map = s.serialize_map(Some(self.len()))?;
        for (k, v) in self.iter() {
            map.serialize_entry(k, v)?;
        }
        map.end()
    }
}

struct ValueVisitor;

impl<'de> Visitor<'de> for ValueVisitor {
    type Value = Value;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_unit<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_none<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        Value::deserialize(d)
    }
    fn visit_bool<E>(self, b: bool) -> Result<Value, E> {
        Ok(Value::Bool(b))
    }
    fn visit_i64<E>(self, n: i64) -> Result<Value, E> {
        Ok(Value::Number(n as f64))
    }
    fn visit_u64<E>(self, n: u64) -> Result<Value, E> {
        Ok(Value::Number(n as f64))
    }
    fn visit_f64<E>(self, n: f64) -> Result<Value, E> {
        Ok(Value::Number(n))
    }
    fn visit_str<E>(self, text: &str) -> Result<Value, E> {
        Ok(Value::String(text.to_string()))
    }
    fn visit_string<E>(self, text: String) -> Result<Value, E> {
        Ok(Value::String(text))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut list = Vec::new();
        while let Some(v) = seq.next_element()? {
            list.push(v);
        }
        Ok(Value::Array(list))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut o = Object::new();
        while let Some((k, v)) = map.next_entry::<String, Value>()? {
            o.set(k, v);
        }
        Ok(Value::Object(o))
    }
}

impl<'de> Deserialize<'de> for Value {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Value, D::Error> {
        d.deserialize_any(ValueVisitor)
    }
}

impl<'de> Deserialize<'de> for Object {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Object, D::Error> {
        match Value::deserialize(d)? {
            Value::Object(o) => Ok(o),
            _ => Err(de::Error::custom("expected a JSON object")),
        }
    }
}

/// Serialize through `to_value`.
macro_rules! through_value {
    ($($name:ty),*) => {
        $(impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                self.to_value().serialize(s)
            }
        })*
    };
}

through_value!(Metrics, Run, JobState, Alert, JobSummary, CheckResult);

impl Serialize for Definition {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.as_object().serialize(s)
    }
}

/// Deserialize through `from_value`, as a store reads the SDK's JSON.
macro_rules! from_value {
    ($($name:ty),*) => {
        $(impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<$name, D::Error> {
                <$name>::from_value(&Value::deserialize(d)?).map_err(de::Error::custom)
            }
        })*
    };
}

from_value!(Metrics, Run, JobState, Alert);

impl<'de> Deserialize<'de> for Definition {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Definition, D::Error> {
        Ok(Definition::from_object(Object::deserialize(d)?))
    }
}

/// The SDK's strings, and back (a value this release does not know is
/// kept as `Other`).
macro_rules! as_text {
    ($($name:ident),*) => {
        $(impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(self.as_str())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<$name, D::Error> {
                Ok($name::parse(&String::deserialize(d)?))
            }
        })*
    };
}

as_text!(RunStatus, Condition, AlertType, JobHealth);
