import { ObjectType, Field, Int } from '@nestjs/graphql';

@ObjectType()
export class Test {
  @Field(() => Int, { description: 'Example field (placeholder)' })
  exampleField: number;
}
