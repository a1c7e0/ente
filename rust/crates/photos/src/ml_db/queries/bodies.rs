use std::collections::HashMap;

use crate::ml_db::{MlDb, Result};

impl MlDb {
    pub fn body_indexes(&self, minimum_version: i64) -> Result<HashMap<i64, String>> {
        self.read_all(
            "SELECT file_id, data FROM body_index WHERE ml_version >= ?",
            [minimum_version],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    }

    pub fn put_body_index(&self, file_id: i64, data: &str, version: i64) -> Result<()> {
        self.execute("INSERT INTO body_index(file_id, data, ml_version) VALUES (?, ?, ?) ON CONFLICT(file_id) DO UPDATE SET data=excluded.data, ml_version=excluded.ml_version", (file_id, data, version))?;
        Ok(())
    }

    pub fn delete_body_indexes(&self, file_ids: &[i64]) -> Result<()> {
        self.execute_chunked_in("DELETE FROM body_index WHERE file_id IN ({})", file_ids)
    }
}

#[cfg(test)]
mod tests {
    use crate::ml_db::MlDb;

    #[test]
    fn body_indexes_are_versioned_replaceable_and_cleared_on_logout() {
        let directory = tempfile::tempdir().unwrap();
        let db = MlDb::open(directory.path().join("ml.db")).unwrap();
        db.put_body_index(1, r#"{"detections":[]}"#, 1).unwrap();
        db.put_body_index(2, "future body", 2).unwrap();
        assert_eq!(db.body_indexes(2).unwrap().len(), 1);
        db.put_body_index(1, "review decision", 1).unwrap();
        assert_eq!(db.body_indexes(1).unwrap()[&1], "review decision");
        db.delete_body_indexes(&[1]).unwrap();
        assert_eq!(db.body_indexes(1).unwrap().len(), 1);
        db.clear_non_pet_tables().unwrap();
        assert!(db.body_indexes(1).unwrap().is_empty());
    }
}
