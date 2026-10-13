# Ledger tables

The tables this agent keeps in its ledger base besides the standard
`Events` table, and the ledger's schema version. Raise `ledger_schema`
by one whenever you add a table or a field; never remove, rename or
retype one. Each table is a `## <Name>` heading, a `key: <Field>` line
naming the field `upsert_rows` matches on, and a `| Field | Type |
Options |` table. See STANDARD.md, "Ledger".

ledger_schema: 1
