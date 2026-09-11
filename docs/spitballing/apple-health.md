Apple Health Importer

In cybort.toml, user will specify a directory such as `/Users/booty/Library/Mobile Documents/com~apple~CloudDocs/Health/`

The file will typically be named `export.zip` but can vary

Any .zip file in the specified directory should be examined as an import

Note that Apple Health exports contain the user's *entire* health history. My personal export.zip is 35MB compressed and ~850MB uncompressed. Each time we import this data, we must do it idempotently and performantly -- 99% of the data in each import will already exist in our database and needs to be skipped. Only a small portion of the file will typically lead to inserts.
